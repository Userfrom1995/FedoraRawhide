#!/bin/bash
if [ -t 0 ] && [ "$EUID" -ne 0 ]; then
    echo "============================================="
    echo "   Welcome to Fedora Rawhide for VMware!     "
    echo "============================================="
    echo "• Default user : fedora (password: fedora)"
    echo "• Sudo access  : Passwordless (wheel group)"
    echo "• Set password : sudo passwd fedora"
    echo "• Update system: sudo dnf5 upgrade"
    echo "============================================="
    echo
fi
