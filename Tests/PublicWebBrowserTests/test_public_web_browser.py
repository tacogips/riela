"""Offline tests for the builtin-owned optional renderer; no Playwright install."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[2] / 'Sources/RielaCLI/Resources/PublicWebBrowser.py'
spec = importlib.util.spec_from_file_location('public_web_browser', SOURCE)
web = importlib.util.module_from_spec(spec)
spec.loader.exec_module(web)


class Route:
    def __init__(self, url, method='GET', kind='fetch', body=None):
        self.request = SimpleNamespace(url=url, method=method, resource_type=kind,
            headers={'accept': '*/*', 'authorization': 'secret', 'cookie': 'secret', 'referer': 'secret'},
            post_data_buffer=body, is_navigation_request=lambda: kind == 'document')
        self.aborted = False
        self.reply = None
    def abort(self): self.aborted = True
    def fulfill(self, **value): self.reply = value


class FakeBrowser:
    def __init__(self, routes):
        self.routes = routes
        self.closed = False
        self.context_args = None
    def __enter__(self): return SimpleNamespace(chromium=self)
    def __exit__(self, *args): pass
    def launch(self, **kwargs): self.launch_args = kwargs; return self
    def new_context(self, **kwargs): self.context_args = kwargs; return self
    def set_default_timeout(self, value): pass
    def add_init_script(self, value): self.script = value
    def route(self, pattern, handler): self.handler = handler
    def route_web_socket(self, pattern, handler): self.websocket = handler
    def new_page(self): return self
    def goto(self, url, **kwargs):
        self.url = url
        self.document = Route(url, kind='document')
        self.handler(self.document)
        for route in self.routes: self.handler(route)
    def wait_for_timeout(self, value): pass
    def evaluate(self, script):
        return {'url': self.url, 'title': 'fixture', 'text': 'rendered', 'links': [], 'published_at': None}
    def close(self): self.closed = True


class PublicWebBrowserTests(unittest.TestCase):
    def dns(self, host, port, **kwargs):
        return [(2, 1, 6, '', ('93.184.216.34' if host == 'example.com' else host, port))]

    def test_policy_blocks_private_addresses_before_transport(self):
        for host in ['127.0.0.1', '169.254.169.254', '10.0.0.1', '[::1]', '[::ffff:127.0.0.1]']:
            with self.subTest(host=host), patch.object(web.socket, 'getaddrinfo', side_effect=self.dns):
                with self.assertRaises(ValueError): web.destination('https://' + host, [])
        with patch.object(web.socket, 'getaddrinfo') as dns:
            with self.assertRaises(ValueError): web.destination('https://api.x.com', ['x.com'])
            dns.assert_not_called()

    def test_every_request_is_intercepted_and_auth_and_cookie_are_removed(self):
        routes = [Route('https://example.com/data'), Route('https://127.0.0.1/private'),
                  Route('https://example.com/redirect'), Route('https://example.com/image', kind='image'),
                  Route('https://example.com/delete', method='DELETE'),
                  Route('https://example.com/large-post', method='POST', body=b'x' * 65537)]
        browser = FakeBrowser(routes)
        calls = []
        def transport(url, method, headers, body, maximum):
            calls.append((url, headers))
            if url.endswith('/redirect'): return 302, {'Location': 'https://169.254.169.254/private'}, b''
            return 200, {'Content-Type': 'text/html', 'Set-Cookie': 'secret', 'Content-Length': '10'}, b'<p>ok</p>'
        with patch.object(web.socket, 'getaddrinfo', side_effect=self.dns):
            result = web.render('https://example.com', {'timeout_ms': 1000, 'wait_ms': 0}, [],
                                transport=transport, playwright=lambda: browser)
        self.assertEqual(result['text'], 'rendered')
        self.assertEqual(browser.context_args, {'service_workers': 'block', 'accept_downloads': False, 'offline': True})
        self.assertTrue(browser.closed)
        self.assertTrue(browser.launch_args['chromium_sandbox'])
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[1][1], {'Accept': '*/*'})
        self.assertEqual(browser.document.reply['headers'], {'Content-Type': 'text/html'})
        self.assertIsNotNone(routes[0].reply)
        for route in routes[1:]: self.assertTrue(route.aborted)
        self.assertIn('WebTransport', browser.script)

    def test_initial_oversized_response_fails(self):
        with patch.object(web.socket, 'getaddrinfo', side_effect=self.dns):
            with self.assertRaisesRegex(ValueError, 'oversized'):
                web.render('https://example.com', {'timeout_ms': 1000, 'wait_ms': 0}, [],
                           transport=lambda *args: (200, {}, b'x' * 2_000_001),
                           playwright=lambda: FakeBrowser([]))


if __name__ == '__main__': unittest.main()
