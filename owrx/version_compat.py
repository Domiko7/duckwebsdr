#
# Compatibility import for version comparison classes.
#
# distutils was removed from the standard library in Python 3.12. Prefer the
# real module when it is available (stdlib before 3.12, or the setuptools
# shim) so that version objects remain comparable with third-party packages
# that still import distutils themselves. Fall back to the vendored copy in
# owrx.distutils_version otherwise.
#
# Do not import distutils anywhere else in this project.
#

try:
    from distutils.version import LooseVersion, StrictVersion  # noqa: F401
except ImportError:
    from owrx.distutils_version import LooseVersion, StrictVersion  # noqa: F401
