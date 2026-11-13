use std::path::PathBuf;

fn main() {
    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let spike = std::env::var_os("SPIKE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest.join("../../toolchain/spike"));
    let inc = spike.join("include");
    let lib = spike.join("lib");
    if !lib.join("libriscv.so").exists() {
        panic!(
            "libriscv.so not found under {}: run `toolchain/fetch.sh spike` or set SPIKE_HOME",
            lib.display()
        );
    }
    cc::Build::new()
        .cpp(true)
        .std("c++2a")
        .file("src/shim.cc")
        .include(&inc)
        .include(inc.join("softfloat"))
        .flag_if_supported("-Wno-unused-parameter")
        .compile("heliodor_spike_shim");
    println!("cargo:rustc-link-search=native={}", lib.display());
    println!("cargo:rustc-link-lib=dylib=riscv");
    println!("cargo:rustc-link-lib=dylib=stdc++");
    // DT_RPATH, not DT_RUNPATH: a host LD_LIBRARY_PATH carrying another
    // spike's libriscv.so must not win over the pinned one.
    println!("cargo:rustc-link-arg=-Wl,--disable-new-dtags");
    println!("cargo:rustc-link-arg=-Wl,-rpath,{}", lib.canonicalize().unwrap().display());
    println!("cargo:rerun-if-env-changed=SPIKE_HOME");
    println!("cargo:rerun-if-changed=src/shim.cc");
}
