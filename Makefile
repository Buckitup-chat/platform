.PHONY: zip burn card ssh test nothing


platform_version := $(shell git log -1 --date=format:%Y-%m-%d --format=%cd_%h)
chat_version := $(shell bash chat_version.sh)
version := "$(platform_version)___$(chat_version)"

nothing: 
	@echo  $(version)


burn: zip 
	mix upload

ssh:
	ssh -i ~/.ssh/buckit.id_rsa nerves.local
	
zip:
	(cd ../chat && make firmware)
	MIX_ENV=prod mix deps.compile chat --force
	mix firmware.image
	rm -f image.*.zip
	rm -f platform.*.fw
	zip image.$(version).zip platform.img
	cp _build/$(MIX_TARGET)_$(MIX_ENV)/nerves/images/platform.fw platform.$(version).fw
	(cd ../chat && make clean)

card:
	fwup _build/rpi4_prod/nerves/images/platform.fw
