.PHONY: 

nothing: 


burn: 
	mix firmware
	mix upload

ssh:
	ssh -i ~/.ssh/buckit.id_rsa nerves.local
	


