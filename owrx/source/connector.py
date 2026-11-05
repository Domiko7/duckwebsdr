from owrx.source import SdrSource, SdrDeviceDescription, SdrSourceState
from owrx.socket import getAvailablePort
from owrx.property import PropertyDeleted
import socket
import threading
from owrx.command import Flag, Option
from typing import List
from owrx.form.input import Input, NumberInput, CheckboxInput, TextInput
from owrx.rtl_tcp_relay import RtlTcpRelay


class ConnectorSource(SdrSource):
    def __init__(self, id, props):
        self.controlSocket = None
        self.controlPort = getAvailablePort()
        self.controlLock = threading.Lock()
        self.localRtlTcpPort = getAvailablePort()
        self.activeRtlTcpPort = None
        self.rtlTcpRelay = None
        super().__init__(id, props)
        self.props.filter(
            "rtltcp_compat", "rtltcp_relay_bind", "rtltcp_relay_port"
        ).wire(self.handleRtlTcpSettingsChange)

    def getCommandMapper(self):
        return (
            super()
            .getCommandMapper()
            .setMappings(
                {
                    "samp_rate": Option("-s"),
                    "tuner_freq": Option("-f"),
                    "port": Option("-p"),
                    "controlPort": Option("-c"),
                    "device": Option("-d"),
                    "iqswap": Flag("-i"),
                    "rtltcp_compat": Option("-r"),
                    "ppm": Option("-P"),
                    "rf_gain": Option("-g"),
                }
            )
        )

    def sendControlMessage(self, changes):
        with self.controlLock:
            if self.controlSocket:
                for prop, value in changes.items():
                    if value is PropertyDeleted:
                        value = None
                    self.logger.debug("sending property change over control socket: {0} changed to {1}".format(prop, value))
                    self.controlSocket.sendall("{prop}:{value}\n".format(prop=prop, value=value).encode())

    def onPropertyChange(self, changes):
        if self.monitor is None:
            return
        if (
            ("center_freq" in changes or "lfo_offset" in changes)
            and "lfo_offset" in self.sdrProps
            and self.sdrProps["lfo_offset"] is not None
        ):
            changes["center_freq"] = self.sdrProps["center_freq"] + self.sdrProps["lfo_offset"]
            changes.pop("lfo_offset", None)
        self.sendControlMessage(changes)

    def postStart(self):
        self.logger.debug("opening control socket...")
        with self.controlLock:
            self.controlSocket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.controlSocket.connect(("localhost", self.controlPort))
        self.startRtlTcpRelay()

    def handleRtlTcpSettingsChange(self, changes):
        if self.getState() == SdrSourceState.RUNNING:
            self.startRtlTcpRelay()
        else:
            self.stopRtlTcpRelay()

    def getLocalRtlTcpPort(self):
        if "rtltcp_compat" in self.props:
            try:
                port = int(self.props["rtltcp_compat"])
                if 0 < port < 65536:
                    return port
            except (TypeError, ValueError):
                pass
        return self.localRtlTcpPort

    def startRtlTcpRelay(self):
        self.stopRtlTcpRelay()
        values = {}
        for key in ["rtltcp_relay_bind", "rtltcp_relay_port"]:
            if key not in self.props:
                return
            value = self.props[key]
            if value is None or value == "" or value == 0:
                return
            values[key] = value
        localPort = self.activeRtlTcpPort or self.getLocalRtlTcpPort()
        try:
            publicPort = int(values["rtltcp_relay_port"])
        except (TypeError, ValueError):
            self.logger.warning("rtl_tcp relay disabled: invalid port number")
            return
        if not (0 < publicPort < 65536):
            self.logger.warning("rtl_tcp relay disabled: port out of range")
            return
        if publicPort == localPort:
            self.logger.error(
                "rtl_tcp relay disabled: network port {0} is already used by the local rtl_tcp port".format(
                    publicPort
                )
            )
            return
        bindAddress = str(values["rtltcp_relay_bind"]).strip()
        self.rtlTcpRelay = RtlTcpRelay(bindAddress, publicPort, "127.0.0.1", localPort)
        self.rtlTcpRelay.start()

    def stopRtlTcpRelay(self):
        if self.rtlTcpRelay is not None:
            self.rtlTcpRelay.stop()
            self.rtlTcpRelay = None

    def stop(self):
        self.stopRtlTcpRelay()
        with self.controlLock:
            super().stop()
            if self.controlSocket:
                self.controlSocket.close()
                self.controlSocket = None

    def getControlPort(self):
        return self.controlPort

    def getCommandValues(self):
        values = super().getCommandValues()
        values["port"] = self.getPort()
        values["controlPort"] = self.getControlPort()
        values["rtltcp_compat"] = self.getLocalRtlTcpPort()
        self.activeRtlTcpPort = values["rtltcp_compat"]
        return values


class ConnectorDeviceDescription(SdrDeviceDescription):
    def getInputs(self) -> List[Input]:
        return super().getInputs() + [
            NumberInput(
                "rtltcp_compat",
                "Local rtl_tcp port",
                infotext="Optional. The device always serves an rtl_tcp stream on localhost; leave this empty to "
                + "pick a port automatically. Set it only when a local program needs a fixed port.",
            ),
            TextInput(
                "rtltcp_relay_bind",
                "Address for the rtl_tcp interface",
                infotext="Network address that shares the local rtl_tcp stream. Empty keeps it localhost-only. "
                + "Use 0.0.0.0 to make it reachable from the network.",
            ),
            NumberInput(
                "rtltcp_relay_port",
                "Network port for the rtl_tcp interface",
                infotext="Port on the address above. It must differ from the local rtl_tcp port and also be "
                + "published by the container.",
            ),
            CheckboxInput(
                "iqswap",
                "Swap I and Q channels",
                infotext="Swapping inverts the spectrum, so this is useful in combination with an inverting mixer",
            ),
        ]

    def getDeviceOptionalKeys(self):
        return super().getDeviceOptionalKeys() + [
            "rtltcp_compat",
            "rtltcp_relay_bind",
            "rtltcp_relay_port",
            "iqswap",
        ]

    def getProfileOptionalKeys(self):
        return super().getProfileOptionalKeys() + ["iqswap"]
