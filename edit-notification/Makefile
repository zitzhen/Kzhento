# Copyright (C) 2026 ZIT STUDIO
# SPDX-License-Identifier: AGPL-3.0-only
#
# Compile the notification catalogues. Run after editing po/*.po; the binaries
# are shipped in the repository as well, because the ISO build must not depend
# on gettext being installed.

PO := $(wildcard po/*.po)
MO := $(PO:.po=.mo)

all: $(MO)

%.mo: %.po
	msgfmt -c -o $@ $<

clean:
	rm -f $(MO)

.PHONY: all clean
