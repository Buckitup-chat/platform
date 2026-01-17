.PHONY: zip burn card ssh test nothing await_restart burn_in cover


platform_version := $(shell git log -1 --date=format:%Y-%m-%d --format=%cd_%h)
chat_version := $(shell bash chat_version.sh)
domain := $(shell cat ./built_for_domain)
version := "$(platform_version)___$(chat_version).$(domain)"

nothing:
	@echo  $(version)

check:
	mix compile --warnings-as-errors

chat_commit := $(shell cd ../chat && git rev-parse HEAD)

prepare_chat:
	@if [ ! -f .chat_compiled ] || [ "$$(cat .chat_compiled)" != "$(chat_commit)" ]; then \
		echo "Chat changed, recompiling..."; \
		(cd ../chat && MIX_ENV=prod make firmware); \
		MIX_ENV=prod mix deps.compile chat --force; \
		echo "$(chat_commit)" > .chat_compiled; \
	else \
		echo "Chat unchanged, skipping recompile"; \
	fi

prepare_chat_old:
	(cd ../chat && MIX_ENV=prod make firmware)
	# Run MIX_ENV=prod MIX_TARGET=bktp_rpi4 mix compile
	# first if the following command fails
	MIX_ENV=prod mix deps.compile chat --force

clean_chat:
	(cd ../chat && MIX_ENV=prod make clean)

faster_burn_in:
	mix firmware
	mix upload

faster_ssh:
	sleep 20
	ssh nerves.local

platform_burn_in: faster_burn_in faster_ssh

full_burn_in: prepare_chat faster_burn_in clean_chat faster_ssh

burn:
	make prepare_chat
	rm -f image.*.zip
	rm -f platform.*.fw
	rm -rf priv/admin_db_v2
	rm -rf priv/db
	mix firmware
	mix upload
	cp _build/$(MIX_TARGET)_$(MIX_ENV)/nerves/images/platform.fw platform.$(version).fw
	make clean_chat

image:
	make prepare_chat
	rm -f image.*.zip
	rm -f platform.*.fw
	rm -rf priv/admin_db_v2
	rm -rf priv/db
	mix firmware
	cp _build/$(MIX_TARGET)_$(MIX_ENV)/nerves/images/platform.fw platform.$(version).fw
	make clean_chat

ssh:
	ssh -i ~/.ssh/buckit.id_rsa -o "StrictHostKeyChecking=no" nerves.local

burn_in: burn await_restart ssh

await_restart:
	sleep 45

zip:
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

