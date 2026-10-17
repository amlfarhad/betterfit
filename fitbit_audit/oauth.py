"""Installed-app OAuth. Credentials and personal records are never logged."""
import base64
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
from pathlib import Path
import secrets
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler

AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth'
TOKEN_URL = 'https://oauth2.googleapis.com/token'
SCOPES = tuple('https://www.googleapis.com/auth/googlehealth.' + s + '.readonly' for s in (
    'activity_and_fitness', 'health_metrics_and_measurements', 'sleep', 'profile'))
PRIVATE = Path(__file__).resolve().parents[1] / '.private' / 'google-health'


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def private_json(path, data):
    path = Path(path)
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError('Private storage cannot use symlinks.')
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix='.writing-')
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_client(path=PRIVATE / 'client-secret.json'):
    config = json.loads(Path(path).read_text())
    client = config.get('installed', {})
    if not client.get('client_id'):
        raise ValueError('A Desktop OAuth client is required.')
    if client.get('token_uri') != TOKEN_URL or client.get('auth_uri') not in (
        AUTH_URL, 'https://accounts.google.com/o/oauth2/auth'):
        raise ValueError('Credentials contain an unexpected OAuth endpoint.')
    return client


def pkce_challenge(verifier):
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode('ascii')).digest()).rstrip(b'=').decode()


def check_callback(query, expected_state):
    fields = parse_qs(query, keep_blank_values=True)
    states = fields.get('state', [])
    if len(states) != 1 or not hmac.compare_digest(states[0], expected_state):
        raise ValueError('Authorization state did not match.')
    if 'error' in fields:
        raise ValueError('Google authorization was not granted.')
    codes = fields.get('code', [])
    if len(codes) != 1 or not codes[0]:
        raise ValueError('Authorization code was missing or ambiguous.')
    return codes[0]


def token_request(fields):
    request = Request(TOKEN_URL, data=urlencode(fields).encode(), method='POST',
                      headers={'Content-Type': 'application/x-www-form-urlencoded'})
    try:
        with build_opener(NoRedirect).open(request, timeout=30) as response:
            token = json.load(response)
    except HTTPError as exc:
        raise ValueError(f'Google token exchange failed (HTTP {exc.code}); retry authorization.') from None
    except (URLError, TimeoutError):
        raise ValueError('Could not reach Google token service.') from None
    if not isinstance(token, dict) or not token.get('access_token'):
        raise ValueError('Google did not return an access token.')
    token['expires_at'] = time.time() + int(token.get('expires_in', 3600))
    return token


def access_token(force_refresh=False):
    path = PRIVATE / 'token.json'
    if not path.exists():
        raise ValueError('Authorize first with: python3 -m fitbit_audit auth')
    token = json.loads(path.read_text())
    if not force_refresh and token.get('expires_at', 0) > time.time() + 60:
        return token['access_token']
    if not token.get('refresh_token'):
        raise ValueError('Authorization expired; run the auth command again.')
    client = load_client()
    fields = {'client_id': client['client_id'], 'grant_type': 'refresh_token',
              'refresh_token': token['refresh_token']}
    if client.get('client_secret'):
        fields['client_secret'] = client['client_secret']
    updated = token_request(fields)
    token.update(updated)
    private_json(path, token)
    return token['access_token']


def authorize(timeout=900):
    client = load_client()
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    deadline = time.time() + timeout
    status_file = PRIVATE / 'auth-status.json'
    result = {'status': 'waiting'}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def respond(self, status, message):
            body = ('<!doctype html><meta charset="utf-8"><title>Fitbit Air account connection</title>'
                    '<meta name="viewport" content="width=device-width, initial-scale=1">'
                    '<main style="font:18px system-ui;max-width:620px;margin:80px auto;padding:24px">'
                    + message + '</main>').encode()
            self.send_response(status)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.headers.get('Host') != f'127.0.0.1:{server.server_port}':
                self.respond(400, 'Invalid local host.')
                return
            parts = urlsplit(self.path)
            if parts.path == '/':
                self.respond(200, '<h1>Connect Fitbit Air</h1><p>This local audit tool requests read-only '
                             'access to activity, health measurements, sleep, and profile information. '
                             'Records will be saved privately on this Mac.</p><p>Google handles sign-in '
                             'and permission approval.</p><a href="/authorize">Continue to Google</a>')
            elif parts.path == '/authorize':
                self.send_response(302)
                self.send_header('Location', authorization_url)
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Referrer-Policy', 'no-referrer')
                self.end_headers()
            elif parts.path == '/callback':
                try:
                    code = check_callback(parts.query, state)
                except ValueError:
                    self.respond(400, 'Authorization could not be verified. Return to the local start page to retry.')
                    return
                try:
                    fields = {'client_id': client['client_id'], 'code': code, 'redirect_uri': redirect_uri,
                              'grant_type': 'authorization_code', 'code_verifier': verifier}
                    if client.get('client_secret'):
                        fields['client_secret'] = client['client_secret']
                    token = token_request(fields)
                    private_json(PRIVATE / 'token.json', token)
                    granted = token.get('scope', '').split()
                    result.update(status='connected', granted_scopes=granted,
                                  missing_requested_scopes=sorted(set(SCOPES) - set(granted)),
                                  connected_at=time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()))
                    private_json(status_file, result)
                    self.respond(200, '<h1>Account connected</h1><p>You can close this tab and return to Codex. '
                                 'Authorization is stored privately on this Mac.</p>')
                except ValueError as exc:
                    result.update(status='error', message=str(exc))
                    private_json(status_file, result)
                    self.respond(502, 'The Google token exchange failed. Return to Codex to retry.')
            else:
                self.respond(404, 'Not found.')

    with HTTPServer(('127.0.0.1', 0), Handler) as server:
        server.timeout = 1
        redirect_uri = f'http://127.0.0.1:{server.server_port}/callback'
        authorization_url = AUTH_URL + '?' + urlencode({
            'client_id': client['client_id'], 'redirect_uri': redirect_uri, 'response_type': 'code',
            'scope': ' '.join(SCOPES), 'state': state, 'code_challenge': pkce_challenge(verifier),
            'code_challenge_method': 'S256', 'access_type': 'offline', 'prompt': 'consent'})
        start_url = f'http://127.0.0.1:{server.server_port}/'
        private_json(PRIVATE / 'auth-session.json', {'start_url': start_url, 'expires_at': deadline})
        private_json(status_file, result)
        print(f'Open {start_url} in your browser to authorize. Waiting up to {timeout // 60} minutes.', flush=True)
        while result['status'] == 'waiting' and time.time() < deadline:
            server.handle_request()
        if result['status'] == 'waiting':
            result.update(status='expired')
            private_json(status_file, result)
        print('Authorization status: ' + result['status'], flush=True)
        return result['status'] == 'connected'
