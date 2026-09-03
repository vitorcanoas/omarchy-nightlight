PLUGIN_DIR ?= $(HOME)/.config/omarchy/plugins/vitorcanoas.nightlight

.PHONY: validate dev

validate:
	omarchy plugin validate .
	bash -n bin/omarchy-nightlight
	bash -n install.sh

# Sync this working tree into the local plugin directory so the running shell
# picks up in-progress changes. The shell reloads plugin code on save; the
# rescan is a best-effort nudge for anything it misses. rsync rather than a
# symlink because omarchy-plugin-validate refuses symlinks inside a plugin.
dev:
	@test -f manifest.json || { printf 'run make dev from the plugin repo root\n' >&2; exit 1; }
	@mkdir -p "$(PLUGIN_DIR)"
	rsync -a --delete --exclude '.git/' ./ "$(PLUGIN_DIR)/"
	omarchy-shell -q shell rescanPlugins
	@printf 'synced to %s\n' "$(PLUGIN_DIR)"
