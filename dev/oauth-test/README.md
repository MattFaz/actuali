# Local OpenID/OAuth test harness

Spins up a [Dex](https://dexidp.io/) OpenID provider + an Actual Budget
sync-server so you can exercise the app's "Sign in with OpenID" flow against a
real OIDC handshake, entirely on your Mac.

## Why `host.docker.internal`?

The OAuth handshake is split across two callers that must agree on **one**
issuer URL:

- the app's in-app browser (`ASWebAuthenticationSession`, on the Mac/simulator)
  hits the **authorization** endpoint;
- the Actual server container hits the **token + userinfo** endpoints.

If the issuer were `localhost`, the container would resolve it to *itself*.
Using `host.docker.internal` everywhere makes the same URL resolve correctly
from both sides.

## One-time setup

1. **Add the hostname to your Mac's `/etc/hosts`** so the simulator's browser
   can resolve it (Docker Desktop already maps it inside containers):

   ```
   127.0.0.1 host.docker.internal
   ```

2. **Start the stack:**

   ```bash
   cd dev/oauth-test
   docker compose up -d
   ```

3. **Sanity-check Dex discovery** — the endpoints should all read
   `host.docker.internal:5556`:

   ```bash
   curl http://host.docker.internal:5556/dex/.well-known/openid-configuration
   ```

4. **Bootstrap Actual + enable OpenID:**
   - Open <http://host.docker.internal:5006> in a browser and set a fallback
     password (this is the bootstrap step Actual requires before OpenID).
   - Enable OpenID from the server settings and paste:
     | Field | Value |
     |-|-|
     | Discovery URL | `http://host.docker.internal:5556/dex/.well-known/openid-configuration` |
     | Client ID | `actuali` |
     | Client secret | `actuali-test-secret` |
     | Server hostname | `http://host.docker.internal:5006` |

5. **Verify** the app will see OpenID:

   ```bash
   curl http://host.docker.internal:5006/account/login-methods
   # → methods should include {"method":"openid","active":1}
   ```

## Testing in the app

Run the app on the **iOS Simulator** (it shares the Mac's network + `/etc/hosts`).

1. Settings → enter Server URL `http://host.docker.internal:5006`, tap **Connect**.
2. A **Sign in with OpenID** button appears → tap it.
3. Log in to Dex with `test@example.com` / `password`.
4. Dex → Actual → the app is redirected back via
   `actuali://localhost/openid-cb?token=…` and lands connected.

> **HTTP note:** the app's API calls run through `URLSession`, which is subject
> to App Transport Security. The **Debug** build includes an ATS exception for
> `host.docker.internal` and local networking so plain `http://` works in the
> simulator. Release builds keep full ATS (real servers should use HTTPS).

## Teardown

```bash
docker compose down -v   # -v also wipes the Actual data volume
```

## The test user

| Field | Value |
|-|-|
| Email | `test@example.com` |
| Password | `password` |

Edit `dex-config.yaml` to add more users (`hash` is bcrypt; generate with
`htpasswd -bnBC 10 "" <password> | tr -d ':\n'`).
