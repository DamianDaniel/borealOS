#!/usr/bin/env python3
import json
import os
import subprocess
import sys
from threading import Thread
import customtkinter as ctk

# Set styling properties
ctk.set_appearance_mode("System")  # Options: "System", "Dark", "Light"
ctk.set_default_color_theme("blue")


class BorealProfileApp(ctk.CTk):
    def __init__(self):
        super().__init__()

        self.title("BorealOS Profile Creator & Deployer")
        self.geometry("750x550")
        self.resizable(False, False)

        # Main Storage Data Structures
        self.system_data = {"system": {}, "packages": {"apt": [], "flatpak": []}}

        # Create Layout
        self.create_widgets()

    def run_cmd(self, cmd):
        try:
            return subprocess.check_output(cmd, shell=True, text=True).strip()
        except Exception:
            return ""

    def create_widgets(self):
        # Header Banner
        self.header = ctk.CTkLabel(self, text="BorealOS Reinstall Utility", font=ctk.CTkFont(size=24, weight="bold"))
        self.header.pack(pady=15)

        # Tab Layout Setup
        self.tabview = ctk.CTkTabview(self, width=700, height=450)
        self.tabview.pack(padx=20, pady=10)

        self.tab_backup = self.tabview.add("Create Reinstall Config")
        self.tab_deploy = self.tabview.add("Load Config For Install")

        self.setup_backup_tab()
        self.setup_deploy_tab()

    # --- TAB 1: BACKUP / EXPORT CONFIG ---
    def setup_backup_tab(self):
        # Scan Button
        self.btn_scan = ctk.CTkButton(self.tab_backup, text="Scan Current System Profile",
                                      command=self.start_system_scan)
        self.btn_scan.pack(pady=10)

        # Status Label
        self.lbl_scan_status = ctk.CTkLabel(self.tab_backup,
                                            text="Click scan to analyze installed apps and system layout.",
                                            text_color="gray")
        self.lbl_scan_status.pack(pady=5)

        # Config preview area (TextBox)
        self.txt_preview = ctk.CTkTextbox(self.tab_backup, width=650, height=250, activate_scrollbars=True)
        self.txt_preview.pack(pady=10)
        self.txt_preview.insert("0.0", "Configuration Manifest Preview will appear here...")
        self.txt_preview.configure(state="disabled")

        # Save Button
        self.btn_save = ctk.CTkButton(self.tab_backup, text="Export Profile to JSON", state="disabled",
                                      command=self.save_profile_dialog)
        self.btn_save.pack(pady=10)

    def start_system_scan(self):
        self.btn_scan.configure(state="disabled")
        self.lbl_scan_status.configure(text="Scanning system packages (APT & Flatpak)... Please wait.",
                                       text_color="cyan")
        # Run inside a background thread so the GUI does not freeze
        Thread(target=self.scan_system_worker, daemon=True).start()

    def scan_system_worker(self):
        # Gather host configuration details
        hostname = self.run_cmd("cat /etc/hostname")
        timezone = self.run_cmd("cat /etc/timezone")
        locale = os.environ.get("LANG", "en_US.UTF-8")

        # Collect user-specified manual packages
        apt_raw = self.run_cmd("apt-mark showmanual")
        apt_list = [p for p in apt_raw.split("\n") if p] if apt_raw else []

        # Collect Flatpaks
        flatpak_raw = self.run_cmd("flatpak list --app --columns=application")
        flatpak_list = [f for f in flatpak_raw.split("\n") if f] if flatpak_raw else []

        self.system_data = {
            "meta": {"distro": "BorealOS", "version": "1.0"},
            "system": {"hostname": hostname, "timezone": timezone, "locale": locale},
            "packages": {"apt": apt_list, "flatpak": flatpak_list}
        }

        # Update GUI from thread safely using scheduling
        self.after(0, self.finish_system_scan)

    def finish_system_scan(self):
        self.btn_scan.configure(state="normal")
        self.btn_save.configure(state="normal")

        apt_count = len(self.system_data["packages"]["apt"])
        flat_count = len(self.system_data["packages"]["flatpak"])
        self.lbl_scan_status.configure(
            text=f"Scan complete! Found {apt_count} APT packages and {flat_count} Flatpak apps.", text_color="green")

        # Render data nicely in textbox previewer
        self.txt_preview.configure(state="normal")
        self.txt_preview.delete("0.0", "end")
        self.txt_preview.insert("0.0", json.dumps(self.system_data, indent=4))
        self.txt_preview.configure(state="disabled")

    def save_profile_dialog(self):
        file_path = ctk.filedialog.asksaveasfilename(
            defaultextension=".json",
            filetypes=[("JSON Files", "*.json")],
            initialfile="boreal_profile.json",
            title="Save BorealOS Config Profile"
        )
        if file_path:
            with open(file_path, "w") as f:
                json.dump(self.system_data, f, indent=4)
            self.lbl_scan_status.configure(text=f"Profile saved to: {os.path.basename(file_path)}", text_color="green")

    # --- TAB 2: DEPLOY PROFILE TO INSTALLERS ---
    def setup_deploy_tab(self):
        self.lbl_deploy_desc = ctk.CTkLabel(
            self.tab_deploy,
            text="Load an existing BorealOS JSON configuration file profile\nto bypass layout questions and auto-install custom application maps.",
            justify="center"
        )
        self.lbl_deploy_desc.pack(pady=20)

        self.btn_load_file = ctk.CTkButton(self.tab_deploy, text="Select Configuration File",
                                           command=self.load_profile_dialog)
        self.btn_load_file.pack(pady=10)

        self.lbl_loaded_details = ctk.CTkLabel(self.tab_deploy, text="No profile loaded yet.", text_color="gray")
        self.lbl_loaded_details.pack(pady=15)

        # Framework Execution Launch Triggers
        self.btn_launch_c = ctk.CTkButton(self.tab_deploy, text="Launch Automated C Installer (GTK)", state="disabled",
                                          fg_color="#1f538d", command=lambda: self.launch_installer("c"))
        self.btn_launch_c.pack(pady=8)

        self.btn_launch_sh = ctk.CTkButton(self.tab_deploy, text="Launch Automated Shell Installer", state="disabled",
                                           fg_color="#2b7122", command=lambda: self.launch_installer("shell"))
        self.btn_launch_sh.pack(pady=8)

        self.loaded_file_path = ""

    def load_profile_dialog(self):
        file_path = ctk.filedialog.askopenfilename(filetypes=[("JSON Files", "*.json")], title="Open BorealOS Profile")
        if file_path:
            try:
                with open(file_path, "r") as f:
                    data = json.load(f)

                # Basic validation check
                if "packages" in data and "system" in data:
                    self.loaded_file_path = file_path
                    apt_len = len(data["packages"].get("apt", []))
                    flat_len = len(data["packages"].get("flatpak", []))
                    host_name = data["system"].get("hostname", "unknown")

                    self.lbl_loaded_details.configure(
                        text=f"Loaded: {os.path.basename(file_path)}\nTarget Hostname: {host_name}\nPackages: {apt_len} APTs, {flat_len} Flatpaks",
                        text_color="green"
                    )
                    self.btn_launch_c.configure(state="normal")
                    self.btn_launch_sh.configure(state="normal")
                else:
                    self.lbl_loaded_details.configure(text="Invalid file format! Profile missing key elements.",
                                                      text_color="red")
            except Exception as e:
                self.lbl_loaded_details.configure(text=f"Failed to read file: {str(e)}", text_color="red")

    def launch_installer(self, engine_type):
        """Spawns your installer binaries passing the configuration path variable payload."""
        if not self.loaded_file_path:
            return

        if engine_type == "c":
            # Assuming your compiled GTK tool is named boreal-installer
            # and takes a configuration path flag parameter asset option
            cmd = f"pkexec boreal-installer --profile '{self.loaded_file_path}'"
        else:
            # Assuming terminal-based interactive architecture context wrapper setup mapping requirements
            cmd = f"x-terminal-emulator -e sudo /opt/borealOS/installer.sh --profile '{self.loaded_file_path}'"

        # Fire off installer window detachment process execution sequence safely
        try:
            subprocess.Popen(cmd, shell=True)
            self.lbl_loaded_details.configure(text=f"Fired installation framework via engine: '{engine_type.upper()}'!",
                                              text_color="yellow")
        except Exception as e:
            self.lbl_loaded_details.configure(text=f"Failed execution stack deployment: {str(e)}", text_color="red")


if __name__ == "__main__":
    app = BorealProfileApp()
    app.mainloop()