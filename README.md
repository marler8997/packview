# packview

Manages views of package sets.

# Usage

```
packview <view_dir> <packages>...
```

## Example
```
packview view gcc make
```

```
packview --download gcc
```

## Ideas for other usages

```
packview myview apt/gcc apt/dmd yum/make apt/bash

packview myview apt/ gcc dmd yum/make apt/bash
```

```
packview myview --apt gcc dmd --yum make --apt bash
```

# Notes/Todos

You can compile and install your own package to packview.
```
./configure --prefix=/var/cache/packview/packs/<name>/sysroot
```

Any dependencies you can put in the deps file
```
cat > /var/cache/packview/packs/<name>/deps <<EOI
foo # use 'foo' from the same package manager
apt/bar # use 'bar' from the apt package manager
yum/baz # use 'baz' from the yum package manager
EOI
```

# Notes on package managers

`packview` requires the package manager to provide the following operations:

1. Query package dependencies
2. Install individual packages to their own sysroot

## Apt and Dpkg

1. Query package dependencies

Uses `apt-depends`.

2. Install individual packages to their own sysroot

I'd like to be able to fetch `.deb` files to the same archive that apt uses for system packages, however, I haven't got this working yet.  For now I use `apt-get download --print-uris` to get the URI of `.deb` files and use that to download them to a global `packview` directory.  Unfortunately, `apt` doesn't seem to have good support for installing packages to their own sysroots, so for now I use `dpkg --extract <deb-file> <dir>`.
