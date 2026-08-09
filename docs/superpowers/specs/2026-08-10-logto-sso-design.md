# new-api × Logto 单点登录 — 设计方案

**日期**：2026-08-10
**背景调研**：`~/Downloads/new-api-SSO-IdP-调研-2026-08-10.md`
**状态**：已确认，待实施

---

## 1. 目标

1. 引入 Logto 作为身份提供方（IdP），new-api 作为 OIDC 接入方（RP）。
2. 不影响现有用户：密码登录长期保留，老用户自愿把 Logto 身份绑定到已有账号。
3. Logto 认证端点、Logto 管理控制台各占一个独立域名，与 new-api 共用同一个 nginx。
4. Logto 保持通用，未来其他站点可作为新的 OIDC client 接入。
5. new-api 升级到当前最新版本，一键部署 / 一键升级脚本保持可用。

## 2. 已确认的决策

| 决策点 | 选择 | 理由 |
|---|---|---|
| 是否改 new-api 源码 | **否**，继续用官方镜像 | 升级永远跟得上上游；不触发 AGPL §13 |
| Logto 数据库 | 复用现有 Postgres 实例，独立库和角色 | 省一个容器；`pg_dump` 仍可按库独立备份恢复 |
| 老用户迁移 | 纯自愿绑定，密码登录长期保留 | 零风险零改动，前端已现成 |
| 主域证书 | 保留现有 BYO 证书 | 避免切换期的证书告警窗口 |
| Logto 两个新域名证书 | Let's Encrypt 自动签发 | 新域名无存量，零切换成本 |
| 创作站取额度 | SSO 引导 + 用户手动贴一把限定 key | 最小权限、可撤销、零源码改动 |
| 备份 | 新增 `pg_dump` 定时备份脚本，覆盖两个库 | Logto 库丢失 = 所有绑定用户登不进来 |

## 3. 代码级事实核实

以下结论来自本仓库源码，不是推断。调研文档中的若干待验证项在此定案。

| 事实 | 位置 |
|---|---|
| Custom OAuth Provider 超时 20s，内置 OIDC 仅 5s | `oauth/generic.go:135,215` vs `oauth/oidc.go:77,124` |
| 前端已为每个 custom provider 渲染「绑定」按钮，迁移零改动 | `web/src/features/profile/components/tabs/account-bindings-tab.tsx`（rc.24 起 `web/default/` 已扁平化为 `web/`） |
| 绑定存于独立表，`(provider_id, provider_user_id)` 唯一，可解绑 | `model/user_oauth_binding.go` |
| **管理员无法代其他用户创建 key**，body 传 `user_id` 被忽略 | `controller/token.go` `AddToken` 用 `c.GetInt("id")`；`/api/token/*` 挂 `UserAuth()` |
| PAT 是 users 表单字段，每次生成覆盖旧值，无过期无作用域 | `controller/user.go` `GenerateAccessToken`；`model/user.go` `ValidateAccessToken` |
| `/api/usage/token`、`/api/log/token` 吃 `sk-` key 且已开 CORS | `middleware/auth.go` `TokenAuthReadOnly`；`router/api-router.go` |
| `/api/user/*`、`/api/token/*` 未挂 CORS，跨域 session 走不通 | `router/api-router.go` |
| passkey RPID 从 `ServerAddress` 推导，改它会让已注册 passkey 失效 | `setting/system_setting/passkey.go:36` |

**结论**：SSO 只解决「这是谁」，不产生 new-api 的授权。Logto 签发的 access_token 打 new-api 用户接口一律 401。

## 4. 升级面：rc.17 → rc.24 是破坏性变更

`31d70fca refactor(auth): replace dashboard sessions with stateless tokens and session control (#6329)`：

- dashboard session 换成无状态 token + refresh cookie（`setupLogin` 返回 `access_token` 与 refresh cookie）。**升级瞬间所有在线用户被登出一次。**
- `SESSION_COOKIE_SECURE=true` 语义变更：启用 Secure Refresh Cookie 与严格 OriginGuard，必须列全可信 HTTPS Origin。
- 新增 `TRUSTED_PROXIES`。留空会打启动告警，默认信任 RFC1918（含 docker bridge，可正常工作）。
- 移除 classic 前端。本仓库 `AGENTS.md` 仍引用 `web/classic/`，合并需处理。
- OAuth state 从 gin session 换成 `auth_flows` 表 + 显式 `intent`（login/bind），绑定流程绑定到当前活跃 session。**对本方案是利好**：绑定成为一等公民且更安全。

因此升级必须是独立阶段、独立验证，不与 Logto 上线混在同一个窗口。

镜像 `calciumion/new-api:v1.0.0-rc.24` 已确认存在。当前 `NEW_API_IMAGE=calciumion/new-api:latest` 意味着每次 `upgrade.sh` 都在做一次未经审查的升级，本次一并钉死。

## 5. 分阶段设计

### Phase 0 — 备份先行

`scripts/backup.sh`：在 postgres 容器内 `pg_dump` 导出 `new_api` 与 `logto` 两库（logto 库不存在则跳过），gzip 落到 `$DATA_ROOT/backups`，按 `BACKUP_RETENTION_DAYS` 清理旧文件。

`deploy.sh` 在 `BACKUP_CRON` 非空时以唯一标记注释幂等安装 crontab 条目；留空则不碰宿主 crontab。

先做这一步，因为 Phase 1 与 Phase 2 都以它兜底。**验收标准是恢复演练成功，而不是脚本能跑通。**

### Phase 1 — 升级到 rc.24

- git 合并 tag `v1.0.0-rc.24`（不是 `upstream/main`），与镜像 tag 对齐。本地提交全部集中在部署文件，Go 代码零冲突预期；冲突集中在 `AGENTS.md` / `README*`，以上游为准后补回部署段落。
- `NEW_API_IMAGE` 钉到 `calciumion/new-api:v1.0.0-rc.24`。
- 新增 `TRUSTED_PROXIES`；`SESSION_COOKIE_SECURE` / `SESSION_COOKIE_TRUSTED_URL` 由 `gen-env.sh` 从 `DOMAIN_NAME` 自动推导写入新生成的 `.env`，避免手敲出错。存量 `.env` 不被自动改写，切换步骤写入运维文档。
- 验证：登录、建 key、relay 调用、管理后台各走一遍。

### Phase 2 — Logto 上线

**compose 服务**

```
image:      svhd/logto:1.42.0        （钉版本，不用 latest）
entrypoint: sh -c "npm run cli db seed -- --swe && npm start"
expose:     3001 (core) / 3002 (admin)，不映射宿主端口
env:        DB_URL / ENDPOINT / ADMIN_ENDPOINT / TRUST_PROXY_HEADER=1
healthcheck: GET /oidc/.well-known/openid-configuration
depends_on: postgres (service_healthy)
```

**数据库供给**（`deploy.sh` 幂等执行）

现有 postgres 卷已初始化，`/docker-entrypoint-initdb.d` 不会再跑，故通过 `docker compose exec postgres psql` 供给：

```sql
-- 角色不存在则创建
DO $$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='logto')
     THEN CREATE ROLE logto LOGIN PASSWORD '...'; END IF; END $$;
-- 库不存在则创建，且必须 OWNER 为 logto
SELECT 'CREATE DATABASE logto OWNER logto'
 WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='logto')\gexec
```

**PG15 坑**：`public` schema 自 PG15 起不再默认授予 PUBLIC 建表权限。必须让 `logto` 成为该库 OWNER，否则 `db seed` 会 permission denied。

**nginx 重构**

现有 `map` 与 `upstream` 写在 `new-api.conf` 内，再渲染第二个 conf 会重复定义、nginx 直接起不来。拆分：

| 文件 | 内容 |
|---|---|
| `_shared.conf`（新，静态提交） | `map $http_upgrade` + `new_api_backend` upstream |
| `new-api.conf.template` | 去掉 map/upstream，只保留 server 块 |
| `logto.conf.template`（新） | `logto_core` upstream + server，按 `LOGTO_DOMAIN` 渲染 |
| `logto-admin.conf.template`（新） | `logto_admin` upstream + server，按 `LOGTO_ADMIN_DOMAIN` 渲染，含可选 IP 白名单 |

`_bootstrap.conf` 无需改动：它的 `listen 80 default_server` 已覆盖全部域名，ACME 挑战与 HTTPS 跳转对三个域名同时生效。

**启动顺序坑**：nginx 在启动时解析 upstream 主机名，`logto` 容器不存在会导致 **nginx 整体起不来、主站一起挂**。因此两个 Logto upstream 声明在各自的渲染文件里，而不是静态的 `_shared.conf`：`LOGTO_ENABLED=false` 时这两个文件根本不渲染（且会被删除），nginx 永远不会引用一个不存在的主机。nginx 也不 `depends_on` logto —— Logto 慢或挂都不得拦住主站。

Logto 服务放在 compose profile `logto` 后面，由 `LOGTO_ENABLED` 驱动，使 Phase 1 的升级可以在完全不涉及 Logto 的情况下独立完成。

**证书：混合模式**

- `CERT_MODE` 语义不变，只管主域，保持 `byo`。
- 新增 `LOGTO_CERT_MODE`（默认 `letsencrypt`），管两个 Logto 域名。
- `init-letsencrypt.sh` 改为接受域名参数，**每域一张独立证书**（不用 SAN：nginx 路径更简单，LE 配额充裕）。其 `rm -rf` 只作用于传入的域名，主域证书目录永不被触碰。
- `deploy.sh` / `upgrade.sh` 的 `check_cert_expiry` 遍历三个域名。
- certbot profile 的启用条件改为 `CERT_MODE=letsencrypt` **或** `LOGTO_CERT_MODE=letsencrypt`。

### Phase 3 — 接入配置（管理后台操作，零代码）

**Logto 侧**

1. 应用类型 **Traditional Web**（new-api 用 client_secret 换 token 且不带 PKCE，选 SPA 会因缺 `code_verifier` 失败）。
2. Redirect URI：`https://<主域>/oauth/logto`
3. SMTP connector 复用现有邮件服务凭证。纯邮箱注册下验证邮件进垃圾箱即用户流失，SPF/DKIM/DMARC 必须配齐。
4. CAPTCHA（Turnstile 或 reCAPTCHA Enterprise）。**注意不覆盖 magic link 与 passkey 登录。**
5. 一次性邮箱域名黑名单是 Logto cloud-only，自部署需定期同步公开列表灌入自定义黑名单。

**new-api 侧：走 Custom OAuth Provider（slug `logto`），不用内置 OIDC**

| 理由 | 说明 |
|---|---|
| 超时 | 20s vs 内置 5s |
| 客户端认证方式 | `auth_style=0` 自动探测，直接消解调研待验证项 #3 |
| 可解绑 | 绑定走 `user_oauth_bindings` 独立表 |
| 不占槽位 | 内置 OIDC 全局唯一，留给将来 |

字段映射照抄内置 keycloak 预设（`sub` / `preferred_username` / `name` / `email`，与 Logto 完全一致），端点以 well-known 返回为准。

**上线前必须核对**：系统设置中的「服务器地址」**逐字符**等于 `https://<主域>`，否则换 token 时 `redirect_uri` 不匹配。**不要为此改动它** —— passkey RPID 从它推导，改动会使已注册 passkey 全部失效。

### Phase 4 — 迁移与运营

- 老用户在 个人设置 → 账号绑定 中看到 Logto 按钮，前端已现成，零改动。
- 密码登录长期保留，**root 账号不绑 Logto**，作为 Logto 故障时的逃生通道。
- 不设迁移截止日，不强制。

## 6. 创作站对接边界（本次只定义，不实现）

创作站作为第二个 Logto 应用接入，与 new-api 共享身份。

| 能力 | 现状 |
|---|---|
| 知道是同一个人 | ✅ SSO 提供 |
| 查**已持有的那把 key** 的余额与用量 | ✅ `GET /api/usage/token`，已开 CORS，浏览器可直连 |
| 列出用户在 new-api 的所有 key | ❌ 需 PAT。PAT 单槽、无过期、无作用域，泄露即全账号权限，不采用 |
| 用户无感自动开 key | ❌ 需改源码 |

**采用路径**：创作站引导用户在 new-api 建一把限模型 / 限额 / 可过期的 key 贴回创作站；余额与用量用同一把 key 打 `/api/usage/token`。最小权限、可撤销、不受 PAT 单槽限制。SSO 让这一步无需重新登录。

Logto 侧本次不建 API resource。

## 7. 明确不做（写入运维文档）

| 项 | 说明 |
|---|---|
| 单点登出 | new-api 登出不会登出 Logto，用户再点登录会瞬间自动进入，观感像登出失败。要做需改前端实现 RP-initiated logout。 |
| 邮箱自动关联 | 老用户若先用 Logto 以同邮箱注册，回调报「邮箱已被占用」。补救：先用密码登录，再在个人设置绑定。写入 FAQ。 |
| 免费额度策略复核 | Logto 注册门槛低于现有邮箱验证码流程。站点背后是按 token 计费的付费网关，上线前应复核新用户赠额。 |

## 8. 变更清单

**修改**
`docker-compose.prod.yml`、`.env.example`、`.gitignore`
`scripts/deploy.sh`、`scripts/upgrade.sh`、`scripts/init-letsencrypt.sh`、`scripts/gen-env.sh`、`scripts/sync.sh`
`nginx/conf.d/new-api.conf.template`

**新增**
`nginx/conf.d/_shared.conf`
`nginx/conf.d/logto.conf.template`、`nginx/conf.d/logto-admin.conf.template`
`scripts/_lib.sh`（deploy / upgrade / init-letsencrypt 共用的证书、渲染、compose 逻辑）
`scripts/backup.sh`
`docs/deploy/logto-sso.md`

**Go / 前端改动：零。**

## 8.1 实施中发现并修复的既有缺陷

两个与 Logto 无关、但会在本次改动后被触发的问题：

1. **重新渲染 nginx 配置后 `up -d` 不会生效**。compose 只在服务定义变化时重建容器，仅改挂载进去的配置文件不会触发重建，nginx 会一直用旧配置直到容器内 6 小时一次的 reload 循环。现在渲染后显式 `nginx -t` 校验并 `nginx -s reload`；校验失败则中止，运行中的站点不受影响。
2. **`.env` 中含空格的值会破坏 `. ./.env`**。`BACKUP_CRON=15 3 * * *` 会被 shell 拆成 `BACKUP_CRON=15` 加一条 `3 * * *` 命令。`BACKUP_CRON` 与 `LOGTO_ADMIN_ALLOW` 均已加引号并在注释中说明原因。

## 9. 回滚

每阶段独立可回滚。

| 阶段 | 回滚方式 |
|---|---|
| Phase 1 | 镜像 tag 退回 rc.17 **并从 Phase 0 的 dump 恢复**。rc.24 的 AutoMigrate 会新增列，只退镜像不够。 |
| Phase 2 | `docker compose stop logto`；nginx 因 upstream 恒定存在仍可启动，Logto 域名返回 502，主站不受影响。 |
| Phase 3 | 在 new-api 管理后台禁用 custom oauth provider。密码登录不受影响，已绑定关系保留在表中，重新启用即恢复。 |
