#!/usr/bin/env python3
# camera-server.py
# Benutze: python3 camera-server.py --device /dev/video0 --port 8080
import argparse
import os
import time
from http import server
import socketserver
import cv2

PAGE = """\
<html>
<head>
<title>Simple MJPEG Stream</title>
</head>
<body>
<h1>MJPEG Stream</h1>
<img src="/stream" />
</body>
</html>
"""

class CamHandler(server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/':
            self.send_response(200)
            self.send_header('Content-type', 'text/html')
            self.end_headers()
            self.wfile.write(PAGE.encode('utf-8'))
        elif self.path == '/stream':
            self.send_response(200)
            self.send_header('Age', '0')
            self.send_header('Cache-Control', 'no-cache, private')
            self.send_header('Pragma', 'no-cache')
            self.send_header('Content-Type', 'multipart/x-mixed-replace; boundary=FRAME')
            self.end_headers()
            try:
                while True:
                    if not cam.grab():
                        continue
                    ret, frame = cam.read()
                    if not ret:
                        continue
                    # encode as JPEG
                    ret2, jpg = cv2.imencode('.jpg', frame, [int(cv2.IMWRITE_JPEG_QUALITY), 80])
                    if not ret2:
                        continue
                    jpg_bytes = jpg.tobytes()
                    self.wfile.write(b'--FRAME\r\n')
                    self.send_header('Content-Type', 'image/jpeg')
                    self.send_header('Content-Length', str(len(jpg_bytes)))
                    self.end_headers()
                    self.wfile.write(jpg_bytes)
                    self.wfile.write(b'\r\n')
                    time.sleep(0.03)  # ~30 fps throttle
            except Exception:
                # client disconnected
                pass
        else:
            self.send_error(404)

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('-d', '--device', default='/dev/video0')
    parser.add_argument('-p', '--port', type=int, default=8080)
    args = parser.parse_args()

    # If set, environment variable silently overrides CLI --device/-d.
    device = os.environ.get('CAMERA_SERVER_DEV') or args.device
    # If set, environment variable silently overrides CLI --port/-p.
    port = int(os.environ.get('CAMERA_SERVER_PORT') or args.port)

    # open camera
    cam = cv2.VideoCapture(device)
    if not cam.isOpened():
        print("Fehler: Kamera konnte nicht geöffnet werden:", device)
        raise SystemExit(1)

    # HTTP server
    with socketserver.TCPServer(("", port), CamHandler) as httpd:
        print("Serving at port", port)
        try:
            httpd.serve_forever()
        finally:
            cam.release()

