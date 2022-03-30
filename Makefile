.PHONY: 

nothing: 


burn: 
	mix firmware
	mix upload

ssh:
	ssh -i ~/.ssh/buckit.id_rsa nerves.local
	
zip:
	(cd ../chat && make firmware)
	mix deps.compile chat --force
	mix firmware.image
	mv image.zip image.old.zip
	zip image.zip platform.img
	(cd ../chat && make clean)

card:
	fwup _build/rpi4_prod/nerves/images/platform.fw
