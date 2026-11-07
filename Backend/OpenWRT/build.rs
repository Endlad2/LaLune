fn main() {
    println!("cargo:rerun-if-env-changed=LALUNE_RAMIPS_CORES");
    let target = std::env::var("TARGET").expect("Cargo target");
    let bundle = if target == "mipsel-unknown-linux-musl" {
        let path = std::env::var_os("LALUNE_RAMIPS_CORES")
            .expect("Для сборки ramips укажите LALUNE_RAMIPS_CORES");
        let path = std::fs::canonicalize(path).expect("ZIP трёх ядер ramips");
        println!("cargo:rerun-if-changed={}", path.display());
        format!("Some(include_bytes!({:?}))", path.to_str().expect("UTF-8 ZIP path"))
    } else {
        "None".into()
    };
    let out = std::path::PathBuf::from(std::env::var_os("OUT_DIR").expect("Cargo output"));
    std::fs::write(
        out.join("ramips_cores.rs"),
        format!("const BUNDLE: Option<&[u8]> = {bundle};\n"),
    )
    .expect("Запись ссылки на архив ядер");
}
