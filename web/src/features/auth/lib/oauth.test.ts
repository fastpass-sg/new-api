/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as
published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/
import assert from 'node:assert/strict'
import { describe, test } from 'node:test'

import type { CustomOAuthProviderInfo } from '../types'

import { buildProviderLogoutUrl } from './oauth'

const REDIRECT = 'https://gateway.example.com/sign-in'

function provider(
  overrides: Partial<CustomOAuthProviderInfo> = {}
): CustomOAuthProviderInfo {
  return {
    id: 1,
    name: 'Logto',
    slug: 'logto',
    icon: '',
    client_id: 'app-id',
    authorization_endpoint: 'https://auth.example.com/oidc/auth',
    scopes: 'openid profile email',
    logout_endpoint: 'https://auth.example.com/oidc/session/end',
    ...overrides,
  }
}

describe('RP-initiated logout URL', () => {
  test('carries the client and post-logout redirect the provider requires', () => {
    const result = buildProviderLogoutUrl(
      'oauth:logto',
      [provider()],
      REDIRECT
    )

    assert.ok(result)
    const url = new URL(result)
    assert.equal(url.origin + url.pathname, 'https://auth.example.com/oidc/session/end')
    assert.equal(url.searchParams.get('client_id'), 'app-id')
    assert.equal(url.searchParams.get('post_logout_redirect_uri'), REDIRECT)
  })

  test('preserves query parameters already present on the endpoint', () => {
    const result = buildProviderLogoutUrl(
      'oauth:logto',
      [
        provider({
          logout_endpoint:
            'https://auth.example.com/oidc/session/end?tenant=default',
        }),
      ],
      REDIRECT
    )

    assert.ok(result)
    assert.equal(new URL(result).searchParams.get('tenant'), 'default')
  })

  test('matches the provider by the slug encoded in the login method', () => {
    const providers = [
      provider({ slug: 'other', client_id: 'other-id' }),
      provider({ slug: 'logto', client_id: 'logto-id' }),
    ]

    const result = buildProviderLogoutUrl('oauth:logto', providers, REDIRECT)

    assert.ok(result)
    assert.equal(new URL(result).searchParams.get('client_id'), 'logto-id')
  })

  // Every case below must keep sign out local rather than sending the browser
  // somewhere it cannot come back from.
  const staysLocal: Array<[string, string | null | undefined, CustomOAuthProviderInfo[] | null | undefined]> = [
    ['password logins', 'password', [provider()]],
    ['passkey logins', 'passkey', [provider()]],
    ['built-in provider logins', 'oauth:github', [provider()]],
    ['a slug with no matching provider', 'oauth:missing', [provider()]],
    ['a provider with no logout endpoint', 'oauth:logto', [provider({ logout_endpoint: '' })]],
    ['a provider with an undefined logout endpoint', 'oauth:logto', [provider({ logout_endpoint: undefined })]],
    ['a malformed logout endpoint', 'oauth:logto', [provider({ logout_endpoint: 'not a url' })]],
    ['an unknown login method', undefined, [provider()]],
    ['no providers loaded', 'oauth:logto', undefined],
  ]

  for (const [name, loginMethod, providers] of staysLocal) {
    test(`returns null for ${name}`, () => {
      assert.equal(buildProviderLogoutUrl(loginMethod, providers, REDIRECT), null)
    })
  }
})
