import boto3, json, os, re
import pg8000.native

sm = boto3.client("secretsmanager")


def handler(event, context):
    tabela = event["tabela"]
    if not re.fullmatch(r"[a-z_][a-z0-9_]*", tabela):
        raise ValueError(f"Nome de tabela invalido: {tabela}")
    seg = json.loads(
        sm.get_secret_value(SecretId=os.environ["DB_SECRET_ARN"])["SecretString"])
    con = pg8000.native.Connection(
        user=seg["username"], password=seg["password"],
        host=os.environ["DB_HOST"], database=os.environ["DB_NAME"], port=5432)
    total = con.run(f"SELECT count(*) FROM {tabela}")[0][0]
    con.close()
    aprovado = total == event["linhas_carregadas"] and total > 0
    return {**event, "qualidade": {"aprovado": aprovado, "no_banco": total}}