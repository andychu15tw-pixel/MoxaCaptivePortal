"""
scripts/remote.py — Reusable SSH/SFTP helper for remote device management.

Usage:
    from scripts.remote import RemoteBox

    box = RemoteBox('10.90.35.36', 'moxa', 'admin@123')
    out, err = box.run('hostname')
    out, err = box.sudo('systemctl status chilli', pw='admin@123')
    box.put('configs/chilli.conf', '/etc/chilli.conf')
    box.close()

Jump host (reach LAN device through gateway):
    gw  = RemoteBox('10.90.35.36', 'moxa', 'admin@123')
    lan = RemoteBox('192.168.182.2', 'moxa', 'moxa', jump=gw)
"""

import paramiko


class RemoteBox:
    def __init__(self, host: str, user: str, password: str,
                 port: int = 22, jump: "RemoteBox | None" = None):
        """
        Connect to a remote host via SSH.

        Args:
            host:     IP or hostname
            user:     SSH username
            password: SSH password
            port:     SSH port (default 22)
            jump:     another RemoteBox to use as jump host (direct-tcpip)
        """
        self.host = host
        self._client = paramiko.SSHClient()
        self._client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        kwargs = dict(
            username=user,
            password=password,
            port=port,
            timeout=10,
            allow_agent=False,
            look_for_keys=False,
        )
        if jump is not None:
            sock = jump._client.get_transport().open_channel(
                "direct-tcpip", (host, port), ("127.0.0.1", 0)
            )
            kwargs["sock"] = sock

        self._client.connect(host, **kwargs)

    # ── Command execution ─────────────────────────────────────────────────

    def run(self, cmd: str, timeout: int = 15) -> tuple[str, str]:
        """Run a command; returns (stdout, stderr) as strings."""
        stdin, stdout, stderr = self._client.exec_command(cmd, timeout=timeout)
        return stdout.read().decode(errors="replace"), stderr.read().decode(errors="replace")

    def sudo(self, cmd: str, pw: str, timeout: int = 15) -> tuple[str, str]:
        """Run a command with sudo, piping password via stdin."""
        return self.run(f"echo '{pw}' | sudo -S {cmd} 2>&1", timeout=timeout)

    def out(self, cmd: str, timeout: int = 15) -> str:
        """Convenience: run and return stdout only (strips trailing newline)."""
        stdout, _ = self.run(cmd, timeout=timeout)
        return stdout.strip()

    # ── File transfer ─────────────────────────────────────────────────────

    def put(self, local_path: str, remote_path: str) -> None:
        """Upload a local file to the remote host via SFTP."""
        sftp = self._client.open_sftp()
        try:
            sftp.put(local_path, remote_path)
        finally:
            sftp.close()

    def get(self, remote_path: str, local_path: str) -> None:
        """Download a file from the remote host via SFTP."""
        sftp = self._client.open_sftp()
        try:
            sftp.get(remote_path, local_path)
        finally:
            sftp.close()

    def read_remote(self, remote_path: str) -> str:
        """Read a remote text file and return its contents as a string."""
        sftp = self._client.open_sftp()
        try:
            with sftp.open(remote_path, "r") as f:
                return f.read().decode(errors="replace")
        finally:
            sftp.close()

    # ── Context manager support ───────────────────────────────────────────

    def close(self) -> None:
        """Close the SSH connection."""
        self._client.close()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


# ── Module-level convenience for this project ────────────────────────────

def moxa_box() -> RemoteBox:
    """Return a connected RemoteBox for the Moxa captive portal gateway."""
    return RemoteBox("10.90.35.36", "moxa", "admin@123")


def ubuntu_client(gw: RemoteBox | None = None) -> RemoteBox:
    """Return a connected RemoteBox for the Ubuntu LAN test client.
    Requires the gateway to be reachable first (jump host).
    """
    if gw is None:
        gw = moxa_box()
    return RemoteBox("192.168.182.2", "moxa", "moxa", jump=gw)
