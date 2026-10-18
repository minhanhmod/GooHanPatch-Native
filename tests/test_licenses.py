"""Tests for license issuance, device limits, expiry and protected downloads."""
import json
import re
import time
import unittest
import test_server

class TestLicenses(unittest.TestCase):
    setUpClass = classmethod(test_server.TestServer.setUpClass.__func__)
    tearDownClass = classmethod(test_server.TestServer.tearDownClass.__func__)
    issue_test_license = classmethod(test_server.TestServer.issue_test_license.__func__)
    request = test_server.TestServer.request
    def test_admin_issuance_revocation_and_device_binding(self):
        code, headers, _ = self.request('/login', data=b'password=a-strong-test-password-123')
        self.assertEqual(code,200)
        cookie = headers.get('Set-Cookie').split(';',1)[0]
        html = self.request('/admin', headers={'Cookie':cookie})[2]
        csrf = re.search(rb'csrf-token" content="([^"]+)',html).group(1).decode()
        auth = {'Cookie':cookie,'X-CSRF-Token':csrf,'Content-Type':'application/json'}
        self.assertIn(b'licenseForm',html)
        config = dict(prefix='MyMOD',days=0,hours=1,quantity=2,max_devices=1,note='integration')
        code, _, data = self.request('/api/admin/licenses',data=json.dumps(config).encode(),headers=auth)
        self.assertEqual(code,200,data)
        codes = json.loads(data)['keys']
        self.assertEqual(len(codes),2)
        self.assertTrue(codes[0].startswith('MYMOD-'))
        self.assertNotEqual(codes[0],codes[1])
        listing = json.loads(self.request('/api/admin/licenses', headers=auth)[2])['licenses']
        row = next(x for x in listing if x['prefix']=='MYMOD')
        self.assertNotIn(codes[0],repr(listing))
        device1={'key':codes[0],'device_id':'1'*32}
        code, _, response = self.request('/api/license/activate',data=json.dumps(device1).encode(),headers={'Content-Type':'application/json'})
        self.assertEqual(code,200,response)
        token=json.loads(response)['token']
        self.assertGreater(json.loads(response)['expires_at'],int(time.time())+3500)
        self.assertEqual(self.request('/api/license/status',headers={'Authorization':'Bearer '+token})[0],200)
        device2={'key':codes[0],'device_id':'2'*32}
        self.assertEqual(self.request('/api/license/activate',data=json.dumps(device2).encode(),headers={'Content-Type':'application/json'})[0],403)
        self.assertEqual(self.request('/api/license/status')[0],401)
        self.assertEqual(self.request('/api/patches',auth=False)[0],401)
        # The second device can activate only after an admin reset.
        krow = next(x for x in listing if x['masked'].endswith(codes[0][-6:]))
        self.assertEqual(self.request('/api/admin/licenses/'+krow['id']+'/reset-devices',data=b'',headers=auth)[0],200)
        self.assertEqual(self.request('/api/license/status',headers={'Authorization':'Bearer '+token})[0],401)
        self.assertEqual(self.request('/api/license/activate',data=json.dumps(device2).encode(),headers={'Content-Type':'application/json'})[0],200)
        self.assertEqual(self.request('/api/admin/licenses/'+krow['id']+'/revoke',data=b'',headers=auth)[0],200)
        self.assertEqual(self.request('/api/license/activate',data=json.dumps(device2).encode(),headers={'Content-Type':'application/json'})[0],403)

    def test_automation_token_cannot_be_called_without_secret(self):
        payload = dict(prefix='AUTO',days=1,hours=2,quantity=1,max_devices=2,note='API')
        raw = json.dumps(payload).encode()
        headers={'Content-Type':'application/json'}
        self.assertEqual(self.request('/api/admin/licenses/auto',data=raw,headers=headers)[0],403)
        headers['Authorization']='Bearer integration-license-admin-token-123456789'
        code, _, result = self.request('/api/admin/licenses/auto',data=raw,headers=headers)
        self.assertEqual(code,200,result)
        self.assertTrue(json.loads(result)['keys'][0].startswith('AUTO-'))

    def test_expired_key_denied_even_for_existing_token(self):
        config = dict(prefix='TIMEOUT',days=0,hours=1,quantity=1,max_devices=1,note='')
        code, headers, _ = self.request('/login',data=b'password=a-strong-test-password-123')
        cookie=headers.get('Set-Cookie').split(';',1)[0]
        csrf=re.search(rb'csrf-token" content="([^"]+)',self.request('/admin',headers={'Cookie':cookie})[2]).group(1).decode()
        auth={'Cookie':cookie,'X-CSRF-Token':csrf,'Content-Type':'application/json'}
        key=json.loads(self.request('/api/admin/licenses',data=json.dumps(config).encode(),headers=auth)[2])['keys'][0]
        payload={'key':key,'device_id':'3'*32}
        token=json.loads(self.request('/api/license/activate',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})[2])['token']
        self.assertEqual(self.request('/api/license/status',headers={'Authorization':'Bearer '+token})[0],200)
        # Server-authoritative expiry; simulate time advancing in DB.
        import sqlite3, pathlib
        with sqlite3.connect(pathlib.Path(self.temp.name)/'patches.sqlite3') as conn:
            import hashlib
            conn.execute('UPDATE license_keys SET expires_at=? WHERE key_hash=?',
                         (int(time.time())-1,hashlib.sha256(key.encode()).hexdigest()))
        self.assertEqual(self.request('/api/license/status',headers={'Authorization':'Bearer '+token})[0],401)
        self.assertEqual(self.request('/api/license/activate',data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})[0],403)

if __name__=='__main__': unittest.main()
