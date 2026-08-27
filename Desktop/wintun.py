import ctypes
import ctypes.wintypes
import os
import platform
import threading
import socket
from pathlib import Path


class WintunAdapter:
    def __init__(self, dll_path):
        self.dll = ctypes.WinDLL(dll_path)
        self.adapter = 0
        self.session = 0
        
        self._setup_functions()
    
    def _setup_functions(self):
        self.dll.WintunCreateAdapter.restype = ctypes.c_void_p
        self.dll.WintunCreateAdapter.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_void_p]
        
        self.dll.WintunOpenAdapter.restype = ctypes.c_void_p
        self.dll.WintunOpenAdapter.argtypes = [ctypes.c_wchar_p]
        
        self.dll.WintunCloseAdapter.argtypes = [ctypes.c_void_p]
        
        self.dll.WintunGetAdapterLUID.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulonglong)]
        
        self.dll.WintunStartSession.restype = ctypes.c_void_p
        self.dll.WintunStartSession.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        
        self.dll.WintunEndSession.argtypes = [ctypes.c_void_p]
        
        self.dll.WintunReceivePacket.restype = ctypes.c_void_p
        self.dll.WintunReceivePacket.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
        
        self.dll.WintunReleaseReceivePacket.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        
        self.dll.WintunAllocateSendPacket.restype = ctypes.c_void_p
        self.dll.WintunAllocateSendPacket.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        
        self.dll.WintunSendPacket.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    
    def create_or_open(self, name="CSQTT"):
        self.adapter = self.dll.WintunCreateAdapter(name, "CSQTT", None)
        if not self.adapter:
            self.adapter = self.dll.WintunOpenAdapter(name)
        if not self.adapter:
            raise RuntimeError("Не удалось создать Wintun-адаптер")
        return self.adapter
    
    def start_session(self, capacity=0x400000):
        self.session = self.dll.WintunStartSession(self.adapter, capacity)
        if not self.session:
            raise RuntimeError("Не удалось открыть Wintun-сессию")
        return self.session
    
    def receive_packet(self):
        size = ctypes.c_uint32(0)
        packet = self.dll.WintunReceivePacket(self.session, ctypes.byref(size))
        if packet:
            data = ctypes.string_at(packet, size.value)
            self.dll.WintunReleaseReceivePacket(self.session, packet)
            return data
        return None
    
    def send_packet(self, data):
        packet = self.dll.WintunAllocateSendPacket(self.session, len(data))
        if not packet:
            return False
        ctypes.memmove(packet, data, len(data))
        self.dll.WintunSendPacket(self.session, packet)
        return True
    
    def close(self):
        if self.session:
            self.dll.WintunEndSession(self.session)
            self.session = 0
        if self.adapter:
            self.dll.WintunCloseAdapter(self.adapter)
            self.adapter = 0


class TunnelController:
    def __init__(self, wintun: WintunAdapter, core_process):
        self.wintun = wintun
        self.core_process = core_process
        self.udp_socket = None
        self.core_port = None
        self.tun_to_core_thread = None
        self.core_to_tun_thread = None
        self.running = False
        
    def start(self, core_port):
        self.core_port = core_port
        self.udp_socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp_socket.bind(('127.0.0.1', 0))
        self.udp_socket.settimeout(0.5)
        
        self.running = True
        
        self.tun_to_core_thread = threading.Thread(target=self._tun_to_core_loop, daemon=True)
        self.core_to_tun_thread = threading.Thread(target=self._core_to_tun_loop, daemon=True)
        
        self.tun_to_core_thread.start()
        self.core_to_tun_thread.start()
    
    def _tun_to_core_loop(self):
        while self.running:
            try:
                packet = self.wintun.receive_packet()
                if packet:
                    self.udp_socket.sendto(packet, ('127.0.0.1', self.core_port))
            except:
                pass
    
    def _core_to_tun_loop(self):
        while self.running:
            try:
                data, addr = self.udp_socket.recvfrom(65535)
                if data:
                    self.wintun.send_packet(data)
            except socket.timeout:
                continue
            except:
                pass
    
    def stop(self):
        self.running = False
        if self.tun_to_core_thread:
            self.tun_to_core_thread.join(timeout=1)
        if self.core_to_tun_thread:
            self.core_to_tun_thread.join(timeout=1)
        if self.udp_socket:
            self.udp_socket.close()
            self.udp_socket = None