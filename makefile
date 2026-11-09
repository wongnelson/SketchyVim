VERSION = "1.0.11"
CC = clang
DEFINES = -DHAVE_CONFIG_H -DMACOS_X -DMACOS_X_DARWIN # -DMANUAL_AX -DGUI_MOVES
LIBS = lib/libvim.a -lm -lncurses -liconv -framework Carbon -framework Cocoa
WARN_FLAGS = -Wall -Wno-array-bounds \
	     -Wno-unknown-warning-option \
	     -Wno-cpp -Wno-pointer-sign \
	     -Wno-unused-parameter \
	     -Wno-strict-overflow \
	     -Wno-return-type -Werror
CFLAGS = $(WARN_FLAGS) $(DEFINES) -g -Ilib -Ilib/libvim/proto -std=c99 -O2 #-fsanitize=address -fsanitize=undefined
ODIR = bin
SRC = src

_OBJ = helpers.om workspace.om event_tap.o ax.o buffer.o line.o env_vars.o window_detector.o
OBJ = $(patsubst %, $(ODIR)/%, $(_OBJ))

.PHONY: all x86 arm64 universal sign lib check-lib clean

all: $(ODIR)/svim
	codesign -fs 'svim-cert' $<

x86: CFLAGS = $(WARN_FLAGS) $(DEFINES) -g -Ilib -Ilib/libvim/proto -std=c99 -O2 -target x86_64-apple-macos12.0
x86: $(ODIR)/svim
	mv $(ODIR)/svim $(ODIR)/svim_x86
	rm -rf $(ODIR)/*.o
	rm -rf $(ODIR)/*.om

arm64: CFLAGS = $(WARN_FLAGS) $(DEFINES) -g -Ilib -Ilib/libvim/proto -std=c99 -O2 -target arm64-apple-macos12.0
arm64: $(ODIR)/svim
	mv $(ODIR)/svim $(ODIR)/svim_arm64
	rm -rf $(ODIR)/*.o
	rm -rf $(ODIR)/*.om

universal:
	$(MAKE) x86
	$(MAKE) arm64
	lipo -create -output $(ODIR)/svim $(ODIR)/svim_x86 $(ODIR)/svim_arm64

sign:
	$(MAKE) universal
	codesign -fs 'svim-cert' $(ODIR)/svim

bundle: clean
	$(MAKE) sign
	@mkdir bundle
	cp $(ODIR)/svim bundle/
	cp -r examples/ bundle/
	tar -czf bundle_$(VERSION).tgz bundle/
	rm -rf bundle/

# Build paths map to "." so the tracked archive names no local directory.
# libvim's makefile hardcodes its clang flags, so a clang wrapper adds the map.
# Its -Werror predates current clang's warnings and C99 checks: both wrappers
# drop -Werror (warnings do not change the code), gcc only runs the probes.
lib: | $(ODIR)
	mkdir -p $(ODIR)/cc
	printf '#!/bin/sh\nexec /usr/bin/clang "$$@" -Wno-error -ffile-prefix-map=$(CURDIR)=.\n' >$(ODIR)/cc/clang
	printf '#!/bin/sh\nexec /usr/bin/gcc "$$@" -Wno-error -Wno-implicit-function-declaration -Wno-implicit-int\n' >$(ODIR)/cc/gcc
	chmod +x $(ODIR)/cc/clang $(ODIR)/cc/gcc
	cd libvim/src/ && PATH="$(CURDIR)/$(ODIR)/cc:$$PATH" make COMPILEDBY=SketchyVim
	cp libvim/src/libvim.a lib/libvim.a
	$(MAKE) check-lib

# Fails when the tracked archive embeds a home directory or this machine's name.
check-lib:
	@! strings lib/libvim.a | grep -E '/(Users|home)/[^/ ]+/' || { echo 'lib/libvim.a embeds local paths; rebuild with make lib' >&2; exit 1; }
	@! strings lib/libvim.a | grep -i -w -F "$$(hostname -s)" || { echo 'lib/libvim.a embeds the build host name; rebuild with make lib' >&2; exit 1; }

bin/svim: $(SRC)/main.m $(OBJ) | $(ODIR)
	$(CC) $(CFLAGS) $^ -o $@ $(LIBS)

$(ODIR)/%.o: $(SRC)/%.c $(SRC)/%.h | $(ODIR)
	$(CC) -c -o $@ $< $(CFLAGS)

$(ODIR)/%.om: $(SRC)/%.m $(SRC)/%.h | $(ODIR)
	$(CC) -c -o $@ $< $(CFLAGS)

$(ODIR):
	mkdir $(ODIR)

.PHONY: clean

clean:
	rm -rf $(ODIR)
