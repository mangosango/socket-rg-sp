"""A small org.bluez service for tests/bluetooth_agent_check.sh. /tmp/mode selects the agent request of Pair."""
import dbus, dbus.service, dbus.mainloop.glib, sys
from gi.repository import GLib
dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
bus = dbus.SystemBus()
name = dbus.service.BusName("org.bluez", bus)
DEV = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
objs = {
    "/org/bluez": {"org.bluez.AgentManager1": {}},
    "/org/bluez/hci0": {"org.bluez.Adapter1": {"Address": "00:11:22:33:44:55", "Name": "pad", "Alias": "pad", "Powered": dbus.Boolean(True), "Discovering": dbus.Boolean(False), "Pairable": dbus.Boolean(True), "Discoverable": dbus.Boolean(False)}},
    DEV: {"org.bluez.Device1": {"Address": "AA:BB:CC:DD:EE:FF", "Name": 'Head "set" \\ one', "Alias": 'Head "set" \\ one', "Paired": dbus.Boolean(False), "Connected": dbus.Boolean(False), "Trusted": dbus.Boolean(False), "Icon": "audio-headset", "RSSI": dbus.Int16(-60), "Adapter": dbus.ObjectPath("/org/bluez/hci0")}},
}
def log(*a):
    print("FAKE", *a, flush=True)
class Root(dbus.service.Object):
    @dbus.service.method("org.freedesktop.DBus.ObjectManager", out_signature="a{oa{sa{sv}}}")
    def GetManagedObjects(self):
        return objs
class Mgr(dbus.service.Object):
    @dbus.service.method("org.bluez.AgentManager1", in_signature="os", sender_keyword="sender")
    def RegisterAgent(self, path, cap, sender=None):
        log("register", path, cap); self.agent = (sender, path)
        open("/tmp/agent-name", "w").write(sender)
    @dbus.service.method("org.bluez.AgentManager1", in_signature="o")
    def RequestDefaultAgent(self, path):
        log("default", path)
    @dbus.service.method("org.bluez.AgentManager1", in_signature="o")
    def UnregisterAgent(self, path):
        log("unregister")
class Props(dbus.service.Object):
    def __init__(self, bus, path, iface):
        super().__init__(bus, path); self.path = path; self.iface = iface
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        return objs[self.path].get(iface, {})
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, iface, prop):
        return objs[self.path][iface][prop]
    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ssv")
    def Set(self, iface, prop, value):
        log("set", prop, value); objs[self.path][iface][prop] = value
        self.PropertiesChanged(iface, {prop: value}, [])
    @dbus.service.signal("org.freedesktop.DBus.Properties", signature="sa{sv}as")
    def PropertiesChanged(self, iface, changed, inval):
        pass
class Adapter(Props):
    @dbus.service.method("org.bluez.Adapter1")
    def StartDiscovery(self):
        log("start-discovery")
    @dbus.service.method("org.bluez.Adapter1")
    def StopDiscovery(self):
        log("stop-discovery")
    @dbus.service.method("org.bluez.Adapter1", in_signature="a{sv}")
    def SetDiscoveryFilter(self, f):
        pass
    @dbus.service.method("org.bluez.Adapter1", in_signature="o")
    def RemoveDevice(self, path):
        log("remove", path)
class Device(Props):
    @dbus.service.method("org.bluez.Device1", async_callbacks=("ok", "err"))
    def Pair(self, ok, err):
        mode = open("/tmp/mode").read().strip()
        log("pair", mode)
        sender, path = mgr.agent
        agent = dbus.Interface(bus.get_object(sender, path), "org.bluez.Agent1")
        def done(*a):
            log("agent-reply", a)
            objs[DEV]["org.bluez.Device1"]["Paired"] = dbus.Boolean(True)
            self.PropertiesChanged("org.bluez.Device1", {"Paired": dbus.Boolean(True)}, [])
            ok()
        def fail(e):
            log("agent-error", e.get_dbus_name())
            err(dbus.DBusException("auth failed", name="org.bluez.Error.AuthenticationFailed"))
        kw = dict(reply_handler=done, error_handler=fail, timeout=30)
        p = dbus.ObjectPath(DEV)
        if mode == "stranger":
            agent.RequestConfirmation(dbus.ObjectPath("/org/bluez/hci0/dev_11_22_33_44_55_66"), dbus.UInt32(999999),
                reply_handler=lambda *a: log("STRANGER-ACCEPTED"), error_handler=lambda e: log("stranger-refused", e.get_dbus_name()), timeout=30)
            agent.RequestAuthorization(dbus.ObjectPath("/org/bluez/hci0/dev_11_22_33_44_55_66"),
                reply_handler=lambda *a: log("STRANGER-AUTHORIZED"), error_handler=lambda e: log("stranger-auth-refused", e.get_dbus_name()), timeout=30)
            agent.RequestConfirmation(p, dbus.UInt32(123456), **kw)
        elif mode == "confirm": agent.RequestConfirmation(p, dbus.UInt32(123456), **kw)
        elif mode == "pin": agent.RequestPinCode(p, **kw)
        elif mode == "passkey": agent.RequestPasskey(p, **kw)
        elif mode == "authorize": agent.RequestAuthorization(p, **kw)
        elif mode == "display":
            agent.DisplayPasskey(p, dbus.UInt32(654321), dbus.UInt16(0), reply_handler=lambda *a: None, error_handler=lambda e: None)
            agent.DisplayPinCode(p, "4321", reply_handler=lambda *a: None, error_handler=lambda e: None)
            GLib.timeout_add(500, lambda: done() and False)
        elif mode == "service": agent.AuthorizeService(p, "0000110b-0000-1000-8000-00805f9b34fb", **kw)
        elif mode == "hang":
            agent.RequestConfirmation(p, dbus.UInt32(111111), **kw)
            GLib.timeout_add(1500, lambda: agent.Cancel(reply_handler=lambda *a: None, error_handler=lambda e: None) and False)
        elif mode == "after":
            ok()
            GLib.timeout_add(200, lambda: agent.AuthorizeService(p, "0000110b-0000-1000-8000-00805f9b34fb",
                reply_handler=lambda *a: log("after-pair-authorized"), error_handler=lambda e: log("AFTER-PAIR-REFUSED")) and False)
        else: ok()
    @dbus.service.method("org.bluez.Device1")
    def Connect(self):
        log("connect")
        raise dbus.DBusException("nope", name="org.bluez.Error.Failed")
    @dbus.service.method("org.bluez.Device1")
    def Disconnect(self):
        log("disconnect")
    @dbus.service.method("org.bluez.Device1")
    def CancelPairing(self):
        log("cancel-pairing")
root = Root(bus, "/"); mgr = Mgr(bus, "/org/bluez"); Adapter(bus, "/org/bluez/hci0", "org.bluez.Adapter1"); Device(bus, DEV, "org.bluez.Device1")
log("ready")
GLib.MainLoop().run()
