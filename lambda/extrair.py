import boto3, csv, io

s3 = boto3.client("s3")

# Registro de datasets aceitos: nome -> colunas obrigatorias no CSV.
# O dataset e identificado pelo inicio do nome do arquivo.
# Para aceitar um arquivo novo, adicione uma entrada aqui e em carregar.py.
DATASETS = {
    "procedures": ["START", "STOP", "PATIENT", "ENCOUNTER", "CODE",
                   "DESCRIPTION", "BASE_COST", "REASONCODE", "REASONDESCRIPTION"],
}


def identificar_dataset(key):
    nome = key.rsplit("/", 1)[-1].lower()
    for dataset in DATASETS:
        if nome.startswith(dataset):
            return dataset
    raise ValueError(
        f"Arquivo nao mapeado em DATASETS: {nome}. Aceitos: {sorted(DATASETS)}")


def ler_csv(corpo_bytes):
    try:
        texto = corpo_bytes.decode("utf-8-sig")
    except UnicodeDecodeError:
        texto = corpo_bytes.decode("latin-1")
    try:
        sep = csv.Sniffer().sniff(texto[:4096], delimiters=",;").delimiter
    except csv.Error:
        sep = ","
    return list(csv.DictReader(io.StringIO(texto), delimiter=sep)), sep


def handler(event, context):
    bucket, key = event["bucket"], event["key"]
    dataset = identificar_dataset(key)
    corpo = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
    linhas, sep = ler_csv(corpo)
    if not linhas:
        raise ValueError(f"Arquivo vazio: s3://{bucket}/{key}")
    faltando = set(DATASETS[dataset]) - set(linhas[0].keys())
    if faltando:
        raise ValueError(f"Colunas ausentes no CSV ({dataset}): {sorted(faltando)}")
    return {"bucket": bucket, "key": key, "dataset": dataset,
            "separador": sep, "total_linhas": len(linhas)}