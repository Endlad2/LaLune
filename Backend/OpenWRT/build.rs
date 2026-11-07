fn main() {
    println!("cargo:rerun-if-env-changed=LALUNE_OPENWRT_CORES");
    let target = std::env::var("TARGET").expect("Cargo target");
    let needs_bundle = matches!(
        target.as_str(),
        "aarch64-unknown-linux-musl" | "mipsel-unknown-linux-musl"
    );

    let bundle = if needs_bundle {
        let path = std::env::var_os("LALUNE_OPENWRT_CORES")
            .expect("Для OpenWRT-сборки укажите LALUNE_OPENWRT_CORES с ZIP трёх ядер");
        let path = std::fs::canonicalize(path).expect("ZIP трёх OpenWRT-ядер");
        println!("cargo:rerun-if-changed={}", path.display());
        format!("Some(include_bytes!({:?}))", path.to_str().expect("UTF-8 ZIP path"))
    } else {
        "None".into()
    };

    let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo output"));
    std::fs::write(
        out.join("bundled_cores.rs"),
        format!("const BUNDLE: Option<&[u8]> = {bundle};\n"),
    )
    .expect("Запись ссылки на архив OpenWRT-ядер");
}
