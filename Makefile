all: ivf_pull

ivf_pull: ivf_pull.m uclop.h
	g++ ivf_pull.m \
		-framework CoreServices \
		-framework Foundation \
		-framework CoreMedia \
		-framework CoreMediaIO \
		-framework CoreVideo \
		-framework AVFoundation \
		-I /usr/local/opt/libjpeg-turbo/include \
		-L/usr/local/opt/libjpeg-turbo/lib \
		-lturbojpeg \
		-lnanomsg \
		-D GitCommit="\"$(GIT_COMMIT)\""\
		-D GitDate="\"$(GIT_DATE)\""\
		-D GitRemote="\"$(GIT_REMOTE)\""\
		-D EasyVersion="\"$(EASY_VERSION)\""\
		-o ivf_pull

clean:
	$(RM) ivf_pull