#!/usr/bin/env python3
"""
Minimal Flask HTTPS application for Istio mesh compliance.
Serves HTTPS on port 443 with self-signed certificates.
"""
import os
import ssl
import json
from datetime import datetime
from flask import Flask, request, jsonify
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
import tempfile

APP_NAME = os.getenv("APP_NAME", "hello-app")
REGION = os.getenv("REGION", "us")

app = Flask(__name__)

def generate_self_signed_cert():
    """Generate self-signed certificate for HTTPS"""
    # Generate private key
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=2048,
    )

    # Create certificate
    subject = issuer = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
        x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "Enterprise"),
        x509.NameAttribute(NameOID.LOCALITY_NAME, "Compliance"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Sample App"),
        x509.NameAttribute(NameOID.COMMON_NAME, APP_NAME),
    ])

    cert = x509.CertificateBuilder().subject_name(
        subject
    ).issuer_name(
        issuer
    ).public_key(
        private_key.public_key()
    ).serial_number(
        x509.random_serial_number()
    ).not_valid_before(
        datetime.utcnow()
    ).not_valid_after(
        datetime.utcnow().replace(year=datetime.utcnow().year + 1)
    ).add_extension(
        x509.SubjectAlternativeName([
        x509.DNSName("localhost"),
        x509.DNSName(APP_NAME),
        x509.DNSName("*.local"),
        ]),
        critical=False,
    ).sign(private_key, hashes.SHA256())

    return private_key, cert

@app.route('/')
def hello():
    """Main application endpoint"""
    return jsonify({
        'message': 'Hello from compliance-ready HTTPS service!',
        'service': APP_NAME,
        'region': REGION,
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'headers': dict(request.headers),
        'remote_addr': request.remote_addr,
        'protocol': request.environ.get('SERVER_PROTOCOL', 'HTTPS'),
        'method': request.method
    })

@app.route('/health')
def health():
    """Health check endpoint for Kubernetes probes"""
    return jsonify({
        'status': 'healthy',
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'service': APP_NAME
    })

@app.route('/ready')
def ready():
    """Readiness check endpoint"""
    return jsonify({
        'status': 'ready',
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'service': APP_NAME
    })

@app.route('/metrics')
def metrics():
    """Basic metrics endpoint for monitoring"""
    return jsonify({
        'service': APP_NAME,
        'status': 'running',
        'timestamp': datetime.utcnow().isoformat() + 'Z',
        'requests_total': 'N/A'  # Simple placeholder
    })

if __name__ == '__main__':
    # Generate self-signed certificate
    private_key, cert = generate_self_signed_cert()

    # Write certificate and key to temporary files
    with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.crt') as cert_file:
        cert_file.write(cert.public_bytes(serialization.Encoding.PEM))
        cert_path = cert_file.name

    with tempfile.NamedTemporaryFile(mode='wb', delete=False, suffix='.key') as key_file:
        key_file.write(private_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption()
        ))
        key_path = key_file.name

    # Create SSL context
    context = ssl.SSLContext(ssl.PROTOCOL_TLSv1_2)
    context.load_cert_chain(cert_path, key_path)

    print(f"Starting HTTPS server on port 443...")
    print(f"Certificate: {cert_path}")
    print(f"Private key: {key_path}")

    # Start HTTPS server
    app.run(
        host='0.0.0.0',
        port=443,
        ssl_context=context,
        debug=False
    )
