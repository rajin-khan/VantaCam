#!/usr/bin/env python3
import argparse
import http.client
import http.server
import ssl
import urllib.parse


HOP_BY_HOP_HEADERS = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
}


def parse_args():
    parser = argparse.ArgumentParser(description="Tiny HTTPS reverse proxy for VantaCam.")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--cert-file", required=True)
    parser.add_argument("--key-file", required=True)
    return parser.parse_args()


def make_handler(target):
    target_url = urllib.parse.urlparse(target)
    if target_url.scheme not in {"http", "https"}:
        raise SystemExit("target must use http or https")
    if not target_url.hostname or not target_url.port:
        raise SystemExit("target must include host and port")

    class ProxyHandler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.proxy()

        def do_POST(self):
            self.proxy()

        def do_PUT(self):
            self.proxy()

        def do_PATCH(self):
            self.proxy()

        def do_DELETE(self):
            self.proxy()

        def do_OPTIONS(self):
            self.proxy()

        def proxy(self):
            body = self.read_body()
            path = self.path
            if target_url.path and target_url.path != "/":
                path = f"{target_url.path.rstrip('/')}/{self.path.lstrip('/')}"

            connection_class = http.client.HTTPSConnection if target_url.scheme == "https" else http.client.HTTPConnection
            connection = connection_class(target_url.hostname, target_url.port, timeout=30)
            headers = self.forward_headers()
            headers["Host"] = target_url.netloc
            headers["X-Forwarded-Proto"] = "https"

            try:
                connection.request(self.command, path, body=body, headers=headers)
                response = connection.getresponse()
                response_body = response.read()
            except Exception as error:
                self.send_error(502, f"upstream error: {error}")
                return
            finally:
                connection.close()

            self.send_response(response.status, response.reason)
            for name, value in response.getheaders():
                if name.lower() in HOP_BY_HOP_HEADERS or name.lower() == "content-length":
                    continue
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)

        def read_body(self):
            length = int(self.headers.get("Content-Length", "0") or "0")
            if length <= 0:
                return None
            return self.rfile.read(length)

        def forward_headers(self):
            return {
                name: value
                for name, value in self.headers.items()
                if name.lower() not in HOP_BY_HOP_HEADERS and name.lower() != "host"
            }

        def log_message(self, format_string, *args):
            print(f"{self.address_string()} - {format_string % args}", flush=True)

    return ProxyHandler


def main():
    args = parse_args()
    handler = make_handler(args.target)
    server = http.server.ThreadingHTTPServer((args.listen_host, args.listen_port), handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert_file, args.key_file)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    print(
        f"serving https://{args.listen_host}:{args.listen_port} -> {args.target}",
        flush=True,
    )
    server.serve_forever()


if __name__ == "__main__":
    main()
