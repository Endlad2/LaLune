fn main() {
    // Убеждаемся что приложение собирается правильно для всех платформ
    println!("cargo:rerun-if-changed=src/");
}
