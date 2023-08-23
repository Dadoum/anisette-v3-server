# anisette-v3-server

A supposedly lighter alternative to [omnisette-server](https://github.com/SideStore/omnisette-server)

Like `omnisette-server`, it supports both currently supported SideStore's protocols (anisette-v1 and 
anisette-v3) but it can also be used with AltServer-Linux.

## Run using Docker

```bash
docker run -d --restart always --name anisette-v3 -p 6969:6969 --volume anisette-v3_data:/home/Alcoholic/.config/anisette-v3/lib/ dadoum/anisette-v3-server
```

## Compile using dub

```bash
apt update && apt install --no-install-recommends -y ca-certificates ldc git clang dub libz-dev libssl-dev
git clone https://github.com/Dadoum/anisette-v3-server.git; cd anisette-v3-server
DC=ldc2 dub build -c "static" --build-mode allAtOnce -b release --compiler=ldc2
stat anisette-v3-server
```

