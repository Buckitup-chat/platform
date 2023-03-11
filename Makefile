.PHONY: zip burn card ssh test nothing await_restart burn_in


platform_version := $(shell git log -1 --date=format:%Y-%m-%d --format=%cd_%h)
chat_version := $(shell bash chat_version.sh)
version := "$(platform_version)___$(chat_version)"

nothing:
	@echo  $(version)

check:
	mix compile --warnings-as-errors

prepare_chat:
	(cd ../chat && MIX_ENV=prod make firmware)
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

burn: zip
	mix upload

ssh:
	ssh -i ~/.ssh/buckit.id_rsa nerves.local

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

stream_camera:
	ffmpeg   -f avfoundation \
	  	-pix_fmt yuyv422 \
	  	-video_size 1280x720 \
	  	-framerate 30 \
	  	-i "0:0" \
	  	-ac 2  \
	  	-vf format=yuyv422 \
	  	-vcodec libx264 \
	  	-maxrate 2000k \
	  	-bufsize 2000k \
	  	-acodec aac\
	  	-ar 44100 \
	  	-b:a 128k \
	  	-f rtp_mpegts udp://127.0.0.1:9988

play_stream:
	ffplay udp://@0.0.0.0:9988
