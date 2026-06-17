SEP = "=" * 40

def format_client(r):
    status   = r.get("Status",          "N/A")
    client   = r.get("Client",          "N/A")
    version  = r.get("Version",         "N/A")
    date     = r.get("BuildDate",       "N/A")
    ami      = r.get("AmiId",           "N/A")
    wsi      = r.get("WsiId",           "N/A")
    bundle   = r.get("BundleId",        "N/A")
    error    = r.get("Error",           "N/A")
    sec_upd  = r.get("SecurityUpdates", "N/A")
    app_upd  = r.get("AppUpdates",      "N/A")
    wsi_desc = r.get("WSIDescription",  "N/A")
    icon     = "OK" if status == "SUCCESS" else ("IGNORE" if status == "SKIPPED" else "ECHEC")

    return (
        "-" * 40 + "\n"
        f"CLIENT  : {client}  [{icon}]\n"
        f"Statut  : {status}\n"
        f"Version : {version}\n"
        f"Date    : {date}\n"
        f"AMI     : {ami}\n"
        f"WSI     : {wsi}\n"
        f"Bundle  : {bundle}\n"
        f"Image   : {wsi_desc}\n"
        f"Erreur  : {error}\n"
        "\nMISES A JOUR WINDOWS :\n"
        f"{sec_upd}\n"
        "\nMISES A JOUR APPLICATIONS :\n"
        f"{app_upd}"
    )


def lambda_handler(event, context):
    results   = event.get("results",    [])
    exec_date = event.get("exec_date",  "N/A")
    exec_name = event.get("exec_name",  "N/A")
    exec_id   = event.get("exec_id",    "")
    nb        = event.get("nb_clients", len(results))

    success = sum(1 for r in results if r.get("Status") == "SUCCESS")
    failed  = sum(1 for r in results if r.get("Status") == "FAILED")
    skipped = sum(1 for r in results if r.get("Status") == "SKIPPED")

    clients_block = "\n\n".join(format_client(r) for r in results)

    region = "eu-central-1"
    sf_url = f"https://{region}.console.aws.amazon.com/states/home#/executions/details/{exec_id}"

    message = (
        SEP + "\n"
        "RAPPORT VDI IMAGE FACTORY\n"
        + SEP + "\n"
        f"Date      : {exec_date}\n"
        f"Execution : {exec_name}\n"
        f"Clients   : {nb}  (Succes: {success}  Echecs: {failed}  Ignores: {skipped})\n"
        + SEP + "\n\n"
        + clients_block + "\n\n"
        + SEP + "\n"
        "ACTIONS:\n"
        "  SUCCESS -> Bundle READY_FOR_DEPLOYMENT\n"
        "  FAILED  -> Verifier DynamoDB (LastWSIError)\n"
        "             et Step Functions logs\n\n"
        + sf_url + "\n"
        + SEP
    )

    subject = f"[VDI Factory] Rapport du {exec_date} - {nb} client(s) | OK:{success} KO:{failed}"

    return {"Subject": subject, "Message": message}
