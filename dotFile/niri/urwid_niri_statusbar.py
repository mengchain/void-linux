import urwid
import subprocess
import threading
import json
import socket
import os
from datetime import datetime

class NiriStatusBar:
    def __init__(self):
        # Create three columns: left, center, right
        self.workspaces = urwid.Text("", align='left')
        self.window_title = urwid.Text("", align='center')
        self.system_info = urwid.Text("", align='right')
        
        self.columns = urwid.Columns([
            self.workspaces,
            ('weight', 2, self.window_title),
            self.system_info
        ])
        
        self.top_bar = urwid.AttrMap(self.columns, 'statusbar')
        self.frame = urwid.Frame(header=self.top_bar, body=urwid.Filler(urwid.Text("")))
        
        self.loop = urwid.MainLoop(
            self.frame,
            palette=[
                ('statusbar', 'white', 'black'),           # Default: white on black
                ('active_ws', 'light green,bold', 'black'), # Active workspace: bold bright green
            ],
            unhandled_input=self.exit_on_q
        )
        
        # Start update threads
        self._start_niri_thread()
        self._start_system_thread()

    def _start_niri_thread(self):
        """Get workspace and window info from niri IPC"""
        def run():
            socket_path = os.environ.get('NIRI_SOCKET')
            if not socket_path:
                self.loop.call_soon_threadsafe(
                    lambda: self.workspaces.set_text("⚠ Niri not running")
                )
                return
            
            while True:
                try:
                    # Connect to niri socket
                    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    sock.connect(socket_path)
                    
                    # Request workspaces info
                    sock.sendall(b'{"Workspaces": null}\n')
                    response = sock.recv(65536).decode()
                    data = json.loads(response)
                    
                    # Parse workspaces with markup
                    ws_markup = self._format_workspaces(data.get('Workspaces', {}))
                    self.loop.call_soon_threadsafe(
                        lambda m=ws_markup: self.workspaces.set_text(m)
                    )
                    
                    sock.close()
                    
                    # Request focused window
                    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                    sock.connect(socket_path)
                    sock.sendall(b'{"FocusedWindow": null}\n')
                    response = sock.recv(65536).decode()
                    data = json.loads(response)
                    
                    title = data.get('FocusedWindow', {}).get('title', '—')
                    self.loop.call_soon_threadsafe(
                        lambda t=title: self.window_title.set_text(t)
                    )
                    
                    sock.close()
                    
                except Exception as e:
                    self.loop.call_soon_threadsafe(
                        lambda: self.workspaces.set_text(f"⚠ Error: {e}")
                    )
                
                import time
                time.sleep(0.5)
        
        threading.Thread(target=run, daemon=True).start()

    def _format_workspaces(self, workspaces):
        """Format workspace list with active indicator using urwid markup"""
        if not workspaces:
            return [('statusbar', "⬚ No workspaces")]
        
        ws_list = [('statusbar', '⬚ ')]  # Workspace symbol
        for i, ws in enumerate(workspaces):
            name = ws.get('name', '?')
            is_active = ws.get('is_active', False)
            
            if i > 0:
                ws_list.append(('statusbar', ' '))
            
            if is_active:
                ws_list.append(('active_ws', f'{name}'))
            else:
                ws_list.append(('statusbar', f'{name}'))
        
        return ws_list

    def _start_system_thread(self):
        """Get network, bluetooth, datetime using standard tools"""
        def run():
            while True:
                try:
                    # Network (get IP address)
                    net_info = self._get_network()
                    
                    # Bluetooth
                    bt = self._get_bluetooth()
                    
                    # DateTime
                    dt = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    
                    status = f"{bt}  {net_info}  🕒 {dt}"
                    self.loop.call_soon_threadsafe(
                        lambda s=status: self.system_info.set_text(s)
                    )
                    
                except Exception as e:
                    self.loop.call_soon_threadsafe(
                        lambda: self.system_info.set_text(f"⚠ Error: {e}")
                    )
                
                import time
                time.sleep(1)
        
        threading.Thread(target=run, daemon=True).start()

    def _get_network(self):
        """Check network connectivity and get IP address"""
        try:
            # Get default route
            result = subprocess.run(['ip', 'route', 'get', '1.1.1.1'], 
                                  capture_output=True, text=True, timeout=1)
            if result.returncode == 0:
                # Parse output to get interface and IP
                parts = result.stdout.split()
                iface = None
                ip_addr = None
                
                for i, part in enumerate(parts):
                    if part == 'dev' and i + 1 < len(parts):
                        iface = parts[i + 1]
                    if part == 'src' and i + 1 < len(parts):
                        ip_addr = parts[i + 1]
                
                if ip_addr:
                    # Determine icon based on interface type
                    if iface and iface.startswith('wl'):
                        return f"📡 {ip_addr}"
                    elif iface and iface.startswith('en'):
                        return f"🌐 {ip_addr}"
                    else:
                        return f"🔗 {ip_addr}"
                
                return "🌐 Connected"
            
            return "📡 —"
        except:
            return "📡 —"

    def _get_bluetooth(self):
        """Check bluetooth status"""
        try:
            result = subprocess.run(['bluetoothctl', 'show'], 
                                  capture_output=True, text=True, timeout=1)
            if 'Powered: yes' in result.stdout:
                # Check if device connected
                devices = subprocess.run(['bluetoothctl', 'devices', 'Connected'],
                                       capture_output=True, text=True, timeout=1)
                if devices.stdout.strip():
                    return "🔵 Connected"
                return "🔵 On"
            return "⚫ Off"
        except:
            return "🔵 —"

    def exit_on_q(self, key):
        if key in ('q', 'Q'):
            raise urwid.ExitMainLoop()

    def run(self):
        self.loop.run()

if __name__ == "__main__":
    NiriStatusBar().run()