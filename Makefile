PLUGIN_DIR ?= $(HOME)/.config/omarchy/plugins/vitorcanoas.nightlight
QMLLINT ?= /usr/lib/qt6/bin/qmllint
OMARCHY_PATH ?= /usr/share/omarchy

.PHONY: validate lint dev

validate:
	omarchy plugin validate .
	git diff --check
	bash -n bin/omarchy-nightlight
	bash -n install.sh

# qmllint needs an import root that CONTAINS a directory named `qs`, because the
# modules are `qs.Ui` and `qs.Commons`. Pointing -I straight at the shell fails
# to resolve them, which looks like a broken plugin and is not.
lint:
	@rm -rf .lint && mkdir -p .lint && ln -s "$(OMARCHY_PATH)/shell" .lint/qs
	-$(QMLLINT) -I .lint -I /usr/lib/qt6/qml Panel.qml
	@rm -rf .lint

# Sync this working tree into the local plugin directory so the running shell
# picks up in-progress changes. The shell reloads plugin code on save; the
# rescan is a best-effort nudge for anything it misses. rsync rather than a
# symlink because omarchy-plugin-validate refuses symlinks inside a plugin.
dev:
	@test -f manifest.json || { printf 'run make dev from the plugin repo root\n' >&2; exit 1; }
	# rsync --delete on the wrong PLUGIN_DIR would empty it, and the cost of
	# being wrong is someone else's installed plugins. Matching "contains
	# /omarchy/plugins/" was not enough: a trailing slash or a "/." component --
	# exactly what a person types for a directory -- left PLUGIN_DIR pointing at
	# the plugins directory ITSELF, where --delete wipes every sibling plugin.
	# So normalise those away first, then demand the path be one level below
	# plugins/ and nothing else.
	@dir='$(PLUGIN_DIR)'; \
	while :; do \
	  case "$$dir" in \
	    */.) dir=$${dir%/.} ;; \
	    */) dir=$${dir%/} ;; \
	    *) break ;; \
	  esac; \
	done; \
	case "$${dir%/*}" in \
	  */omarchy/plugins) ;; \
	  *) printf 'refusing to sync to %s: PLUGIN_DIR must name a directory directly under omarchy/plugins/\n' "$$dir" >&2; exit 1 ;; \
	esac; \
	case "$${dir##*/}" in \
	  ''|.|..) printf 'refusing to sync to %s: that is the plugins directory itself, not a plugin\n' "$$dir" >&2; exit 1 ;; \
	esac; \
	mkdir -p "$$dir"; \
	rsync -a --delete --exclude '.git/' --exclude '.lint/' ./ "$$dir/" || exit 1; \
	omarchy-shell -q shell rescanPlugins; \
	printf 'synced to %s\n' "$$dir"
