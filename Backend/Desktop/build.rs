fn main() {
    let version = std::env::var("LALUNE_VERSION")
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rustc-env=LALUNE_VERSION={version}");
    println!("cargo:rerun-if-env-changed=LALUNE_VERSION");
}
