.PHONY: zip burn card ssh test nothing await_restart burn_in cover


platform_version := $(shell git log -1 --date=format:%Y-%m-%d --format=%cd_%h)
chat_version := $(shell bash chat_version.sh)
version := "$(platform_version)___$(chat_version)"

nothing:
	@echo  $(version)

check:
	mix compile --warnings-as-errors

prepare_chat:
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

