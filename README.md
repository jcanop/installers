# Installers
Install scripts for various projects for Debian Linux.

## Usages
Download a particular script or clone the whole repository, and then run with the sudo command.
~~~
$ git clone https://github.com/jcanop/installers.git
$ cd installers
$ sudo ./[script name]
~~~

Or download and execute in one line.
~~~
$ curl --proto '=https' --tlsv1.2 -sSf https://raw.githubusercontent.com/jcanop/installers/main/[script name] | bash
~~~

## Available install scripts

| Script | Description |
| ------ | ----------- |
| install\_bind\_exporter.sh | Installs the Prometheus' Bind Exporter in a Linux-AMD64 machine. |
| install\_node\_exporter.sh | Installs the Prometheus' Node Exporter in a Linux-AMD64 machine. |
