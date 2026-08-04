"""
ETL raw (CSV) -> silver (Parquet) para o data lake da clinica.

Estrategia:
  - Lista os .csv de s3://<raw>/<prefixo> (padrao: incoming/).
  - Uma TABELA POR ARQUIVO, nomeada pelo nome do arquivo sem extensao
    (procedures.csv -> tabela "procedures"). A versao anterior agrupava por
    subpasta de 1o nivel - com o layout incoming/, todos os CSVs (schemas
    diferentes!) seriam concatenados numa unica tabela "incoming".
  - Separador: "auto" detecta por arquivo (pandas engine=python), cobrindo
    "," (Synthea) e ";" (sistemas BR) no mesmo bucket.
  - Encoding: "auto" tenta utf-8 (com BOM) e cai para latin-1.
  - Grava Parquet (snappy) em s3://<silver>/<tabela>/ com mode=overwrite
    (idempotente: rodar de novo substitui, nunca duplica).
  - Registra/atualiza a tabela diretamente no Glue Data Catalog - sem
    depender de crawler.

Parametros do job (definidos no Terraform, sobrescreviveis por execucao):
  --RAW_BUCKET      bucket de origem (CSVs)
  --RAW_PREFIX      prefixo dentro do bucket (ex: incoming/)
  --SILVER_BUCKET   bucket de destino (Parquet)
  --GLUE_DATABASE   database do catalogo onde registrar as tabelas
  --CSV_SEP         separador ("auto" recomendado; ou "," / ";")
  --CSV_ENCODING    encoding ("auto" recomendado; ou "utf-8" / "latin-1")
"""

import re
import sys
from collections import defaultdict

import awswrangler as wr
from awsglue.utils import getResolvedOptions

args = getResolvedOptions(
    sys.argv,
    ["RAW_BUCKET", "RAW_PREFIX", "SILVER_BUCKET", "GLUE_DATABASE", "CSV_SEP", "CSV_ENCODING"],
)

RAW = args["RAW_BUCKET"]
PREFIX = args["RAW_PREFIX"].lstrip("/")
SILVER = args["SILVER_BUCKET"]
DB = args["GLUE_DATABASE"]
SEP = args["CSV_SEP"]
ENC = args["CSV_ENCODING"]


def sanitize(name: str) -> str:
    """Nome de tabela/coluna seguro para Glue/Athena: minusculo, [a-z0-9_]."""
    name = name.strip().lower()
    name = re.sub(r"[^\w]+", "_", name, flags=re.ASCII)
    return re.sub(r"_+", "_", name).strip("_") or "tabela"


def read_group(paths: list[str]):
    """Le um grupo de CSVs com deteccao de separador/encoding conforme config."""
    kwargs = {}
    if SEP == "auto":
        # engine=python + sep=None: o pandas fareja o separador por arquivo
        kwargs.update(sep=None, engine="python")
    else:
        kwargs.update(sep=SEP)

    encodings = ["utf-8-sig", "latin-1"] if ENC == "auto" else [ENC]
    last_err = None
    for enc in encodings:
        try:
            return wr.s3.read_csv(paths, encoding=enc, **kwargs)
        except UnicodeDecodeError as exc:
            last_err = exc
    raise last_err


def main() -> None:
    keys = wr.s3.list_objects(f"s3://{RAW}/{PREFIX}", suffix=[".csv", ".CSV"])
    if not keys:
        print(f"ERRO: nenhum .csv encontrado em s3://{RAW}/{PREFIX}")
        sys.exit(1)

    # Uma tabela por arquivo (stem). Arquivos com mesmo stem em subpastas
    # diferentes sao concatenados de proposito (particoes manuais do mesmo dataset).
    groups: dict[str, list[str]] = defaultdict(list)
    for full_path in keys:
        filename = full_path.rsplit("/", 1)[-1]
        groups[sanitize(filename.rsplit(".", 1)[0])].append(full_path)

    print(f"{len(keys)} arquivo(s) CSV -> {len(groups)} tabela(s): {sorted(groups)}")

    failures = []
    for table, paths in sorted(groups.items()):
        try:
            df = read_group(paths)
            df.columns = [sanitize(c) for c in df.columns]

            result = wr.s3.to_parquet(
                df=df,
                path=f"s3://{SILVER}/{table}/",
                dataset=True,
                mode="overwrite",
                database=DB,
                table=table,
                index=False,
                compression="snappy",
            )
            print(
                f"OK  {table}: {len(df)} linhas, {len(df.columns)} colunas, "
                f"{len(result['paths'])} arquivo(s) parquet"
            )
        except Exception as exc:  # noqa: BLE001 - queremos continuar as demais
            print(f"ERRO {table}: {exc}")
            failures.append(table)

    if failures:
        print(f"Falha em {len(failures)} tabela(s): {failures}")
        sys.exit(1)

    print("Concluido. Rode 'Sync database schema' no Metabase para enxergar.")


if __name__ == "__main__":
    main()
