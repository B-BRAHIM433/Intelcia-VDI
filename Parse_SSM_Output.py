def lambda_handler(event, context):

    def extract_block(text, start_marker, end_marker):
        if not text:
            return "N/A"
        start = text.find(start_marker)
        end   = text.find(end_marker)
        if start != -1 and end != -1:
            return text[start + len(start_marker):end].strip()
        return None  # Return None if markers not found

    def extract_app_details(text):
        if not text:
            return "N/A"
        lines = []
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("Mises a jour") or line.startswith("Ignorees"):
                lines.append(line)
        detail = extract_block(text, "APP_UPDATE_DETAIL_START", "APP_UPDATE_DETAIL_END")
        if detail:
            lines.append(detail)
        return "\n".join(lines) if lines else text[:300].strip()

    def sanitize(text):
        import re
        text = re.sub(r'[^a-zA-Z0-9 _.:/=+\-@]', '', text)
        text = re.sub(r'-{2,}', '-', text)
        text = re.sub(r' {2,}', ' ', text)
        return text.strip()[:255]

    def is_valid_tech_str(text):
        import re
        return bool(re.match(r'^Win\d{5}\.\d+', text.strip()))

    import re
    from datetime import datetime

    security_raw = event.get("security_output", "")
    apps_raw     = event.get("apps_output",     "")
    client       = event.get("client",          "Unknown")
    today        = datetime.utcnow().strftime("%Y-%m-%d")

    # ── Security summary ──────────────────────────────────────────────────────
    security_summary = extract_block(security_raw, "UPDATES_SUMMARY_START", "UPDATES_SUMMARY_END")
    if not security_summary:
        security_summary = "N/A"

    # ── Extract build and KB from security summary ────────────────────────────
    build_str = None
    latest_kb = None

    if security_summary and security_summary != "N/A":
        build_match = re.search(r'Build\s+(\d{5}\.\d+)', security_summary)
        if build_match:
            build_str = build_match.group(1)

        main_kb_match = re.search(r'MAIN_KB=(KB\d{6,})', security_summary)
        if main_kb_match:
            latest_kb = main_kb_match.group(1)

        if not latest_kb and build_str:
            build_num = build_str.split('.')[0]
            for line in security_summary.splitlines():
                if build_num in line and re.search(r'KB\d{6,}', line):
                    kb_m = re.search(r'KB(\d{6,})', line)
                    if kb_m:
                        latest_kb = f"KB{kb_m.group(1)}"
                        break

        if not latest_kb:
            skip_words = ['.NET', 'Framework', 'Defender', 'Antivirus',
                          'Antimalware', 'Definition', 'selection disjointe', 'Malicious']
            for line in security_summary.splitlines():
                if re.search(r'KB\d{6,}', line):
                    if not any(w in line for w in skip_words):
                        kb_m = re.search(r'KB(\d{6,})', line)
                        if kb_m:
                            latest_kb = f"KB{kb_m.group(1)}"
                            break

    # ── Tech string from apps output ──────────────────────────────────────────
    tech_str = extract_block(apps_raw, "WSI_DESCRIPTION_START", "WSI_DESCRIPTION_END")

    # Validate tech_str - if markers missing or content invalid, build from security data
    if not tech_str or not is_valid_tech_str(tech_str):
        # Markers not found or content is garbage (e.g. winget progress bars)
        build_part = f"Win{build_str}" if build_str else "WinUnknown"
        kb_part    = latest_kb if latest_kb else "N/A"
        tech_str   = f"{build_part}-{kb_part}"

    # ── Replace build and KB in tech_str with correct values ─────────────────
    if build_str:
        tech_str = re.sub(r'Win\d{5}\.\d+', f'Win{build_str}', tech_str)
    if latest_kb:
        parts = tech_str.split('-')
        if len(parts) >= 2:
            parts[1] = latest_kb
            tech_str = '-'.join(parts)

    full_desc = f"{client} - {today} - {tech_str}"
    wsi_description = sanitize(full_desc)

    return {
        "SecurityUpdates": security_summary,
        "AppUpdates":      extract_app_details(apps_raw),
        "WSIDescription":  wsi_description
    }
