#!/usr/bin/env python3
import json
import time
import urllib.error
import urllib.request

BASE_IP = "127.0.0.1"
CANDIDATE_URLS = [
    "http://" + BASE_IP + "/zabbix/api_jsonrpc.php",
    "http://" + BASE_IP + "/api_jsonrpc.php"
]

ADMIN_PASS_FILE = "/var/db/zabbix-install/admin-password"
DEFAULT_PASS = "zabbix"
ACTIVE_API_URL = None


def zbx_call(method, params, token=None, url=None):
    target_url = url or ACTIVE_API_URL
    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1
    }
    headers = {"Content-Type": "application/json-rpc"}
    if token:
        headers["Authorization"] = f"Bearer {token}"

    req = urllib.request.Request(
        target_url,
        data=json.dumps(payload).encode("utf-8"),
        headers=headers
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {e.code} ({method}): {err_body}") from e

    data = json.loads(body)
    if "error" in data:
        raise RuntimeError(f"Zabbix API chyba ({method}): {data['error']}")
    return data["result"]


def wait_for_api():
    global ACTIVE_API_URL
    last_err = None
    for _ in range(30):
        for url in CANDIDATE_URLS:
            try:
                zbx_call("apiinfo.version", [], url=url)
                ACTIVE_API_URL = url
                print(f"==> Zabbix API dostupné na: {ACTIVE_API_URL}")
                return
            except Exception as e:
                last_err = e
        time.sleep(2)
    raise RuntimeError(f"Zabbix API neodpovídá. Poslední chyba: {last_err}")


def get_or_create_group(token, name):
    groups = zbx_call("hostgroup.get", {"filter": {"name": [name]}}, token)
    if groups:
        return next(iter(groups))["groupid"]
    res = zbx_call("hostgroup.create", {"name": name}, token)
    return next(iter(res["groupids"]))


def main():
    wait_for_api()
    with open(ADMIN_PASS_FILE, "r") as f:
        new_admin_pass = f.read().strip()

    password_changed = False
    try:
        token = zbx_call("user.login", {"username": "Admin", "password": DEFAULT_PASS})
    except Exception:
        token = zbx_call("user.login", {"username": "Admin", "password": new_admin_pass})
        password_changed = True

    spos_group_id = get_or_create_group(token, "SPOS Lab")
    cert_group_id = get_or_create_group(token, "Web Certificate")

    # 1. Host spos-zabbix8 (Linux by Zabbix agent)
    hosts = zbx_call("host.get", {"filter": {"host": ["spos-zabbix8"]}}, token)
    if not hosts:
        templates = zbx_call("template.get", {"filter": {"host": ["Linux by Zabbix agent"]}}, token)
        template_ids = [{"templateid": next(iter(templates))["templateid"]}] if templates else []
        zbx_call("host.create", {
            "host": "spos-zabbix8",
            "groups": [{"groupid": spos_group_id}],
            "templates": template_ids,
            "interfaces": [{
                "type": 1,
                "main": 1,
                "useip": 1,
                "ip": "127.0.0.1",
                "dns": "",
                "port": "10050"
            }]
        }, token)
        print("==> Host 'spos-zabbix8' vytvořen.")

    # 2. Host sposdk.cz + položka sposdk.cert.days
    cert_hosts = zbx_call("host.get", {"filter": {"host": ["sposdk.cz"]}}, token)
    if not cert_hosts:
        res = zbx_call("host.create", {
            "host": "sposdk.cz",
            "groups": [
                {"groupid": spos_group_id},
                {"groupid": cert_group_id}
            ],
            "interfaces": [{
                "type": 1,
                "main": 1,
                "useip": 1,
                "ip": "127.0.0.1",
                "dns": "",
                "port": "10050"
            }]
        }, token)
        host_id = next(iter(res["hostids"]))
        host_ifaces = zbx_call("hostinterface.get", {"hostids": host_id}, token)
        iface_id = next(iter(host_ifaces))["interfaceid"]

        zbx_call("item.create", {
            "name": "Platnost TLS certifikatu sposdk.cz (dny)",
            "key_": "sposdk.cert.days",
            "hostid": host_id,
            "type": 0,
            "value_type": 3,
            "interfaceid": iface_id,
            "delay": "1h"
        }, token)
        print("==> Host 'sposdk.cz' a položka 'sposdk.cert.days' vytvořeny.")

    # 3. Změna hesla uživatele Admin
    # 3. Změna hesla uživatele Admin
    if not password_changed:
        users = zbx_call("user.get", {"filter": {"username": ["Admin"]}}, token)
        admin_id = next(iter(users))["userid"]
        zbx_call("user.update", {
            "userid": admin_id,
            "current_passwd": DEFAULT_PASS,
            "passwd": new_admin_pass
        }, token)
        print("==> Heslo účtu Admin bylo bezpečně přenastaveno.")



if __name__ == "__main__":
    main()
