import urwid
import subprocess
import threading
import json
import socket
import os
import re
from datetime import datetime

class NiriStatusBar:
    def __init__(self):
        # Create status widgets
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
                ('statusbar', 'white', 'black'),
                ('active_ws', 'light green,bold', 'black'),
            ],
            unhandled_input=self.exit_on_q
        )
        
        # Cached system info components
        self.bluetooth_status = "🔵 —"
        self.network_status = "📡 —"
        self.audio_status = "🔊 —"
        
        # Start threads
        self._start_niri_event_thread()
        self._start_audio_event_thread()
        self._start_network_thread()
        self._start_bluetooth_thread()
        self._start_clock_thread()

    def _start_niri_event_thread(self):
        """Subscribe to niri event stream for workspaces and windows"""
        def run():
            socket_path = os.environ.get('NIRI_SOCKET')
            if not socket_path:
                self.loop.call_soon_threadsafe(
                    lambda: self.workspaces.set_text("⚠ Niri not running")
                )
                return
            
            try:
                sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                sock.connect(socket_path)
                
                # Subscribe to event stream
                sock.sendall(b'{"EventStream": null}\n')
                sock.recv(1024)  # Read initial OK response
                
                # Get initial state
                self._update_workspaces()
                self._update_window_title()
                
                # Listen for events
                buffer = ""
                while True:
                    data = sock.recv(4096).decode()
                    if not data:
                        break
                    
                    buffer += data
                    
                    while '\n' in buffer:
                        line, buffer = buffer.split('\n', 1)
                        line = line.strip()
                        if not line:
                            continue
                        
                        try:
                            event = json.loads(line)
                            
                            # Handle workspace events
                            if 'WorkspacesChanged' in event or 'WorkspaceActivated' in event:
                                self._update_workspaces()
                            
                            # Handle window events
                            if 'WindowFocusChanged' in event or 'WindowClosed' in event or 'WindowOpenedOrChanged' in event:
                                self._update_window_title()
                        
                        except json.JSONDecodeError:
                            continue
                
            except Exception as e:
                self.loop.call_soon_threadsafe(
                    lambda: self.workspaces.set_text(f"⚠ Niri error: {e}")
                )
        
        threading.Thread(target=run, daemon=True).start()

    def _update_workspaces(self):
        """Query current workspaces state"""
        try:
            socket_path = os.environ.get('NIRI_SOCKET')
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            sock.connect(socket_path)
            
            sock.sendall(b'{"Workspaces": null}\n')
            response = sock.recv(65536).decode()
            data = json.loads(response)
            
            ws_markup = self._format_workspaces(data.get('Workspaces', {}))
            self.loop.call_soon_threadsafe(
                lambda m=ws_markup: self.workspaces.set_text(m)
            )
            
            sock.close()
        except Exception:
            pass

    def _update_window_title(self):
        """Query focused window"""
        try:
            socket_path = os.environ.get('NIRI_SOCKET')
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
        except Exception:
            pass

    def _format_workspaces(self, workspaces):
        """Format workspace list with active indicator"""
        if not workspaces:
            return [('statusbar', "⬚ No workspaces")]
        
        ws_list = [('statusbar', '⬚ ')]
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

    def _start_audio_event_thread(self):
        """Monitor audio volume changes via pactl subscribe"""
        def run():
            try:
                # Get initial volume
                self._update_audio_volume()
                
                # Subscribe to pulseaudio events
                proc = subprocess.Popen(
                    ['pactl', 'subscribe'],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    universal_newlines=True,
                    bufsize=1
                )
                
                for line in proc.stdout:
                    # Update on sink (output) events
                    if 'sink' in line.lower() or 'server' in line.lower():
                        self._update_audio_volume()
                        self._update_system_info()
                
            except Exception as e:
                self.audio_status = f"🔊 Error"
                self._update_system_info()
        
        threading.Thread(target=run, daemon=True).start()

    def _update_audio_volume(self):
        """Get current audio volume and mute status"""
        try:
            # Get default sink volume
            result = subprocess.run(
                ['pactl', 'get-sink-volume', '@DEFAULT_SINK@'],
                capture_output=True,
                text=True,
                timeout=1
            )
            
            # Parse volume (e.g., "Volume: front-left: 65536 / 100% / 0.00 dB")
            volume_match = re.search(r'(\d+)%', result.stdout)
            volume = int(volume_match.group(1)) if volume_match else 0
            
            # Check mute status
            mute_result = subprocess.run(
                ['pactl', 'get-sink-mute', '@DEFAULT_SINK@'],
                capture_output=True,
                text=True,
                timeout=1
            )
            
            is_muted = 'yes' in mute_result.stdout.lower()
            
            # Format status with appropriate icon
            if is_muted:
                self.audio_status = "🔇 Muted"
            elif volume == 0:
                self.audio_status = "🔈 0%"
            elif volume < 33:
                self.audio_status = f"🔈 {volume}%"
            elif volume < 66:
                self.audio_status = f"🔉 {volume}%"
            else:
                self.audio_status = f"🔊 {volume}%"
        
        except Exception:
            self.audio_status = "🔊 —"

    def _start_network_thread(self):
        """Poll network status (no native event system)"""
        def run():
            while True:
                self.network_status = self._get_network()
                self._update_system_info()
                import time
                time.sleep(5)  # Check every 5 seconds
        
        threading.Thread(target=run, daemon=True).start()

    def _start_bluetooth_thread(self):
        """Poll bluetooth status"""
        def run():
            while True:
                self.bluetooth_status = self._get_bluetooth()
                self._update_system_info()
                import time
                time.sleep(5)  # Check every 5 seconds
        
        threading.Thread(target=run, daemon=True).start()

    def _start_clock_thread(self):
        """Update clock every second"""
        def run():
            while True:
                self._update_system_info()
                import time
                time.sleep(1)
        
        threading.Thread(target=run, daemon=True).start()

    def _update_system_info(self):
        """Update the right side of status bar"""
        dt = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        status = f"{self.bluetooth_status}  {self.network_status}  {self.audio_status}  🕒 {dt}"
        
        self.loop.call_soon_threadsafe(
            lambda s=status: self.system_info.set_text(s)
        )

    def _get_network(self):
        """Check network connectivity and get IP address"""
        try:
            result = subprocess.run(['ip', 'route', 'get', '1.1.1.1'], 
                                  capture_output=True, text=True, timeout=1)
            if result.returncode == 0:
                parts = result.stdout.split()
                iface = None
                ip_addr = None
                
                for i, part in enumerate(parts):
                    if part == 'dev' and i + 1 < len(parts):
                        iface = parts[i + 1]
                    if part == 'src' and i + 1 < len(parts):
                        ip_addr = parts[i + 1]
                
                if ip_addr:
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