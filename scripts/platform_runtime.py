RUNTIME_PACKAGES = {
    'archlinuxarm': (
        'bash', 'coreutils', 'findutils', 'systemd', 'util-linux', 'kmod',
        'glibc', 'openssl', 'bluez', 'bluez-utils', 'networkmanager',
        'python', 'python-gobject', 'pyside6', 'kirigami', 'kirigami-addons',
        'kconfig', 'kcoreaddons', 'ki18n', 'kscreen', 'kdialog',
        'qt6-base', 'qt6-declarative', 'qt6-multimedia', 'qt6-sensors',
        'qt6-svg', 'qt6-wayland', 'exiv2', 'libva', 'libdrm', 'libyaml',
        'libevent', 'libjpeg-turbo', 'libtiff', 'gnutls', 'gstreamer',
        'gst-plugins-base', 'libqmi', 'libqrtr-glib', 'protobuf-c',
        'e2fsprogs', 'libgudev', 'libunwind', 'hostapd', 'dnsmasq',
        'nftables', 'iw', 'iproute2', 'polkit', 'upower', 'rtkit',
        'plasma-login-manager', 'wireless-regdb', 'alsa-utils', 'alsa-ucm-conf',
        'pipewire', 'pipewire-audio', 'pipewire-pulse', 'pipewire-libcamera',
        'wireplumber', 'gst-plugin-pipewire', 'iio-sensor-proxy', 'v4l-utils',
    ),
    'armada': (
        'bash', 'coreutils', 'findutils', 'systemd', 'util-linux', 'kmod',
        'python3', 'python3-gobject', 'python3-pyside6', 'bluez', 'NetworkManager',
        'e2fsprogs', 'hostapd', 'dnsmasq', 'nftables', 'iw', 'iproute',
        'wireless-regdb', 'rtkit', 'polkit', 'upower', 'glib2',
        'qt6-qtbase', 'qt6-qtdeclarative', 'qt6-qtmultimedia', 'qt6-qtsensors',
        'qt6-qtsvg', 'qt6-qtwayland', 'kf6-kirigami', 'kf6-kirigami-addons',
        'kf6-kconfig', 'kf6-kcoreaddons', 'kf6-ki18n', 'kscreen', 'kdialog',
        'alsa-utils', 'alsa-ucm', 'pipewire', 'pipewire-pulseaudio',
        'pipewire-utils', 'pipewire-plugin-libcamera', 'pipewire-gstreamer', 'wireplumber',
        'iio-sensor-proxy', 'v4l-utils',
    ),
    # Debian package names in the trixie archive.  The multiarch library
    # packages keep their t64 names so the platform .deb resolves cleanly.
    'debian': (
        'bash', 'coreutils', 'findutils', 'systemd', 'util-linux', 'kmod',
        'python3', 'python3-gi', 'python3-pyside6.qtwidgets', 'bluez',
        'network-manager', 'e2fsprogs', 'hostapd', 'dnsmasq', 'nftables',
        'iw', 'iproute2', 'wireless-regdb', 'rtkit', 'polkitd', 'upower',
        'libglib2.0-0t64', 'libqt6core6t64', 'libqt6qml6', 'libqt6multimedia6',
        'libqt6sensors6', 'libqt6svg6', 'libqt6waylandclient6',
        'qml6-module-org-kde-kirigami', 'qml6-module-org-kde-kirigamiaddons-components',
        'qml6-module-org-kde-config', 'qml6-module-org-kde-coreaddons',
        'qml6-module-org-kde-i18n-localedata', 'kdialog', 'alsa-utils',
        'pipewire', 'pipewire-pulse', 'wireplumber',
        'iio-sensor-proxy', 'v4l-utils', 'plasma-workspace', 'plasma-desktop',
    ),
    # ROCKNIX is Buildroot-based and has no package manager.  These names are
    # the upstream Buildroot packages the payload is linked against; the
    # payload records them in usr/share/caihong-platform/runtime-dependencies
    # so a mismatch is visible when ROCKNIX changes its package set.
    'rocknix': (
        'systemd', 'bluez', 'networkmanager', 'pipewire', 'wireplumber',
        'alsa-lib', 'alsa-utils', 'python3', 'python3-gobject',
        'qt6base', 'qt6declarative', 'qt6multimedia', 'qt6sensors', 'qt6svg',
        'qt6wayland', 'kirigami', 'kconfig', 'kcoreaddons', 'ki18n',
        'libdrm', 'libva', 'mesa', 'iio-sensor-proxy', 'v4l-utils',
        'inputplumber', 'wireless-regdb',
    ),
}
