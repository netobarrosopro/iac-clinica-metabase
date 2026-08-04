import boto3, csv, io, json, os
import pg8000.native

s3 = boto3.client("s3")
sm = boto3.client("secretsmanager")

# Registro de datasets: coluna do CSV -> tipo no Postgres.
# A tabela recebe o nome do dataset, colunas em minusculas.
# Estrategia de carga: full refresh (TRUNCATE + COPY na mesma transacao).
DATASETS = {
    "procedures": {
        "START": "timestamptz",
        "STOP": "timestamptz",
        "PATIENT": "text",
        "ENCOUNTER": "text",
        "CODE": "text",
        "DESCRIPTION": "text",
        "BASE_COST": "numeric",
        "REASONCODE": "text",
        "REASONDESCRIPTION": "text",
    },
}


def conectar(database):
    seg = json.loads(
        sm.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])["SecretString"])
    return pg8000.native.Connection(
        user=seg["username"], password=seg["password"],
        host=os.environ["DB_HOST"], database=database, port=5432)


def ler_csv(corpo_bytes, sep):
    try:
        texto = corpo_bytes.decode("utf-8-sig")
    except UnicodeDecodeError:
        texto = corpo_bytes.decode("latin-1")
    return csv.DictReader(io.StringIO(texto), delimiter=sep)


def handler(event, context):
    if event.get("acao") == "criar_database":
        con = conectar("postgres")
        existe = con.run("SELECT 1 FROM pg_database WHERE datname = 'analytics'")
        if not existe:
            con.run("CREATE DATABASE analytics")
        con.close()
        return {"status": "database analytics pronto"}

    dataset = event["dataset"]
    schema = DATASETS[dataset]          # KeyError aqui = dataset nao mapeado
    colunas = list(schema)
    cols_ddl = ", ".join(f"{c.lower()} {t}" for c, t in schema.items())
    cols_copy = ", ".join(c.lower() for c in colunas)

    corpo = s3.get_object(Bucket=event["bucket"], Key=event["key"])["Body"].read()
    leitor = ler_csv(corpo, event.get("separador", ","))

    # Reescreve o CSV apenas com as colunas do schema, na ordem do schema
    # (campo vazio sem aspas -> NULL no COPY)
    buffer = io.StringIO()
    escritor = csv.writer(buffer)
    total = 0
    for linha in leitor:
        escritor.writerow([linha.get(c, "") for c in colunas])
        total += 1
    buffer.seek(0)

    con = conectar(os.environ["DB_NAME"])
    con.run(f"CREATE TABLE IF NOT EXISTS {dataset} "
            f"({cols_ddl}, carga_ts timestamptz DEFAULT now())")
    con.run("BEGIN")
    con.run(f"TRUNCATE {dataset}")
    con.run(f"COPY {dataset} ({cols_copy}) FROM STDIN WITH (FORMAT csv, NULL '')",
            stream=buffer)
    con.run("COMMIT")
    con.close()
    return {**event, "tabela": dataset, "linhas_carregadas": total}