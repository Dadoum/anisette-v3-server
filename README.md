# anisette-v3-server

A supposedly lighter alternative to [omnisette-server](https://github.com/SideStore/omnisette-server)

Like `omnisette-server`, it supports both currently supported SideStore's protocols (anisette-v1 and 
anisette-v3) but it can also be used with AltServer-Linux.

## Run using Docker

```bash
docker run -d --restart always --name anisette-v3 -p 6969:6969 --volume anisette-v3_data:/home/Alcoholic/.config/anisette-v3/lib/ dadoum/anisette-v3-server
```

## The identity of the server

The ADI libraries this server loads are the ones shipped in the Apple Music
application for Android, so the server is an Android device as far as Apple is
concerned. Since October 2026, Apple's GrandSlam compares the platform
advertised in `X-Mme-Client-Info` with the platform of the ADI library that
produced the one-time password, and refuses the request with `-80045` ("This
action cannot be completed at this time.") when the two disagree. The server
therefore advertises the Android identity by default, and `--client-info` /
`--user-agent` (or the `ANISETTE_CLIENT_INFO` / `ANISETTE_USER_AGENT`
environment variables) can be used to declare a different one.

```bash
docker run -d --name anisette-v3 -p 6969:6969 \
  --volume anisette-v3_data:/home/Alcoholic/.config/anisette-v3/lib/ \
  dadoum/anisette-v3-server \
  --client-info "<PC> <Windows;6.2(0,0);9200> <com.apple.iTunes/12.9.3>"
```

Keep in mind that Apple routes clients to a different GrandSlam service
depending on the platform that is advertised, so a client that talks to
`gsa.apple.com` directly needs to follow the URL bag
(`https://gsa.apple.com/grandslam/GsService2/lookup`) to find out which
service to use.

## Compile using dub

```bash
apt update && apt install --no-install-recommends -y ca-certificates ldc git clang dub libz-dev libssl-dev
git clone https://github.com/Dadoum/anisette-v3-server.git; cd anisette-v3-server
DC=ldc2 dub build -c "static" --build-mode allAtOnce -b release --compiler=ldc2
stat anisette-v3-server
```

## Build the Docker image locally

The GitHub Actions workflow publishes `dadoum/anisette-v3-server` for `linux/386`, `linux/amd64`, and `linux/arm64/v8` only. `linux/arm/v7` is not built by Actions because LDC builds under QEMU are unreliable for that target.

If you need an ARMv7 image, build it locally on a native ARMv7 system or other environment that can produce a compatible binary:

```bash
docker buildx build --platform linux/arm/v7 -t dadoum/anisette-v3-server:armv7 .
```

## Ansible

If you want to quickly setup anisette-v3 with ansible, just use the setup-anisette-v3-ansible.yaml playbook.
Setup your inventory and choose your desired host in the playbook. Tweak your parameters/ansible.cfg for the remote_user you use. Requires root.
```bash
ansible-playbook -i inventory setup-anisette-v3-ansible.yaml -k
```