// Keeps the console window from flashing up behind the app on Windows.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

fn main() {
    framegrab_lib::run()
}
