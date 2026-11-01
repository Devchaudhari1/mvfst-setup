# Quic installation guidelines

- Use the --allow-system-packages flag to allow existing kali system packages/dependencies to be substituted for packages built explicitly by mvfst


```
cd /home/dev/Desktop/mvfst

./build/fbcode_builder/getdeps.py \
    --allow-system-packages \
    build mvfst \
    --num-jobs 2\
    --install-prefix="$(pwd)/_build"
```

