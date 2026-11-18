.PHONY: zip burn card ssh test nothing await_restart burn_in cover \
	ssh_lan ssh_usb burn_lan burn_usb burn_in_lan burn_in_usb \
	faster_burn_in_lan faster_burn_in_usb upload

HOST_LAN := buckitup-lan
HOST_USB := buckitup-usb

HOST_PORT ?= 22
SSH_KEY := ~/.ssh/buckit.id_rsa
FW_PATH = _build/$(MIX_TARGET)_$(MIX_ENV)/nerves/images/platform.fw

platform_version := $(shell git log -1 --date=format:%Y-%m-%d --format=%cd_%h)
chat_version := $(shell bash chat_version.sh)
frontend_version := $(shell bash frontend_version.sh)
domain := $(shell cat ./built_for_domain)
ifeq ($(strip $(domain)),)
$(error built_for_domain is missing or empty, put the target domain there (e.g. buckitup.app))
endif
version := "$(platform_version)___$(chat_version)___$(frontend_version).$(domain)"

nothing:
	@echo  $(version)

check:
	mix compile --warnings-as-errors

# Build stamps include the domain: the frontend bakes DOMAIN into its bundle
# and chat reads it at compile time, so a domain switch must force a rebuild.
# chat's `make firmware` also rebuilds the frontend, so the chat stamp covers it too.
chat_commit := $(shell cd ../chat && git rev-parse HEAD)
chat_stamp := $(chat_commit) $(frontend_version) $(domain)

prepare_chat:
	@if [ ! -f .chat_compiled ] || [ "$$(cat .chat_compiled)" != "$(chat_stamp)" ]; then \
		echo "Chat, frontend or domain changed, recompiling for $(domain)..."; \
		(cd ../chat && DOMAIN=$(domain) MIX_ENV=prod make firmware); \
		DOMAIN=$(domain) MIX_ENV=prod mix deps.compile chat --force; \
		echo "$(chat_stamp)" > .chat_compiled; \
	else \
		echo "Chat unchanged for $(domain), skipping recompile"; \
	fi

prepare_chat_old:
	(cd ../chat && MIX_ENV=prod make firmware)
	# Run MIX_ENV=prod MIX_TARGET=bktp_rpi4 mix compile
	# first if the following command fails
	MIX_ENV=prod mix deps.compile chat --force

frontend_commit := $(shell cd ../chat-frontend && git rev-parse HEAD)
frontend_stamp := $(frontend_commit) $(domain)

prepare_frontend:
	@if [ ! -f .frontend_compiled ] || [ "$$(cat .frontend_compiled)" != "$(frontend_stamp)" ]; then \
		echo "Frontend or domain changed, rebuilding for $(domain)..."; \
		(cd ../chat && DOMAIN=$(domain) make frontend-build); \
		echo "$(frontend_stamp)" > .frontend_compiled; \
	else \
		echo "Frontend unchanged for $(domain), skipping rebuild"; \
	fi

clean_chat:
	(cd ../chat && MIX_ENV=prod make clean)

upload:
	cat $(FW_PATH) | ssh -i $(SSH_KEY) -p $(HOST_PORT) -s -- $(HOST) fwup

faster_burn_in:
	mix firmware
	$(MAKE) upload HOST=$(HOST)

faster_ssh:
	sleep 20
	ssh $(HOST)

platform_burn_in: faster_burn_in faster_ssh

full_burn_in: prepare_frontend prepare_chat faster_burn_in clean_chat faster_ssh

burn:
	make prepare_frontend
	make prepare_chat
	rm -f image.*.zip
	rm -f platform.*.fw
	rm -rf priv/admin_db_v2
	rm -rf priv/db
	mix firmware
	$(MAKE) upload HOST=$(HOST)
	cp $(FW_PATH) platform.$(version).fw
	make clean_chat

image:
	make prepare_frontend
	make prepare_chat
	rm -f image.*.zip
	rm -f platform.*.fw
	rm -rf priv/admin_db_v2
	rm -rf priv/db
	mix firmware
	cp _build/$(MIX_TARGET)_$(MIX_ENV)/nerves/images/platform.fw platform.$(version).fw
	make clean_chat

ssh:
	ssh -i $(SSH_KEY) -o "StrictHostKeyChecking=no" $(HOST)

burn_in: burn await_restart ssh

ssh_lan:
	$(MAKE) ssh HOST=$(HOST_LAN)

ssh_usb:
	$(MAKE) ssh HOST=$(HOST_USB)

burn_lan:
	$(MAKE) burn HOST=$(HOST_LAN)

burn_usb:
	$(MAKE) burn HOST=$(HOST_USB)

burn_in_lan:
	$(MAKE) burn_in HOST=$(HOST_LAN)

burn_in_usb:
	$(MAKE) burn_in HOST=$(HOST_USB)

faster_burn_in_lan:
	$(MAKE) faster_burn_in HOST=$(HOST_LAN)

faster_burn_in_usb:
	$(MAKE) faster_burn_in HOST=$(HOST_USB)

await_restart:
	sleep 45

zip:
	make prepare_frontend
	make prepare_chat
	mix firmware.image
	rm -f image.*.zip
	rm -f platform.*.fw
	zip image.$(version).zip platform.img
	cp _build/$(MIX_TARGET)_$(MIX_ENV)/nerves/images/platform.fw platform.$(version).fw
	make clean_chat

card:
	fwup _build/$(MIX_TARGET)_$(MIX_ENV)/nerves/images/platform.fw

add_ip_alias:
	sudo ifconfig en0 192.168.24.200 netmask 255.255.255.0 alias

del_ip_alias:
	sudo ifconfig en0 -alias 192.168.24.200

cover:
	mix coveralls.html

test:
	MIX_TARGET=host MIX_ENV=test mix test $(filter-out $@,$(MAKECMDGOALS))

firmware_build:
	CMAKE_POLICY_VERSION_MINIMUM=3.5 mix firmware

# This rule prevents Make from trying to run arguments as targets
%:
	@:

