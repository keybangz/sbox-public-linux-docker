FROM ubuntu:noble

LABEL maintainer="tsktp"

ENV WINEPREFIX=/wine
ENV WINEARCH=win64
ENV DISPLAY=:0

RUN dpkg --add-architecture i386

RUN apt-get update -q && \
    apt-get install -qq wget curl gpg
RUN wget -O - https://dl.winehq.org/wine-builds/winehq.key | gpg --dearmor -o /etc/apt/keyrings/winehq-archive.key
RUN wget -NP /etc/apt/sources.list.d/ https://dl.winehq.org/wine-builds/ubuntu/dists/noble/winehq-noble.sources

RUN apt-get update -qq && \
	apt-get install -qq git xvfb winbind wine64 wine32:i386 cabextract bzip2 && \
	apt-get clean -qq all

RUN wget https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks && \
	chmod +x winetricks && \
	mv winetricks /usr/bin/

RUN wget --no-check-certificate https://symantec.tbs-certificats.com/vsign-universal-root.crt && \
	mkdir -p /usr/local/share/ca-certificates/extra && \
	cp vsign-universal-root.crt /usr/local/share/ca-certificates/extra/vsign-universal-root.crt && \
	update-ca-certificates && \
	rm vsign-universal-root.crt
