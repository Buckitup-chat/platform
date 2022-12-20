.PHONY: zip burn card ssh test nothing


platform_version := $(shell git log -1 --date=format:%Y-%m-%d --format=%cd_%h)
chat_version := $(shell bash chat_version.sh)
version := "$(platform_version)___$(chat_version)"

nothing: 
	@echo  $(version)

check:
	mix compile --warnings-as-errors

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
