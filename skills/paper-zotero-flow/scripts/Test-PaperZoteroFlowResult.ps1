[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$ExpectedSchema
)

$ErrorActionPreference = 'Stop'
$SupportedSchemas = @(
    'paper-record.v1',
    'download-result.v1',
    'zotero-result.v1',
    'translation-result.v1',
    'verification-result.v1'
)
$RequiredProperties = @(
    'schema',
    'schema_version',
    'paper_id',
    'status',
    'inputs',
    'outputs',
    'provenance',
    'errors'
)

try {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Stage result does not exist: $Path"
    }
    $json = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $result = $json | ConvertFrom-Json
    foreach ($property in $RequiredProperties) {
        if ($null -eq $result.PSObject.Properties[$property]) {
            throw "Stage result is missing required property: $property"
        }
    }
    if ($SupportedSchemas -notcontains [string]$result.schema) {
        throw "Unsupported stage-result schema: $($result.schema)"
    }
    if ([string]$result.schema -ne $ExpectedSchema) {
        throw "Expected schema '$ExpectedSchema' but received '$($result.schema)'"
    }
    if ([int]$result.schema_version -ne 1) {
        throw "Unsupported schema version: $($result.schema_version)"
    }
    $parsedPaperId = [guid]::Empty
    if (-not [guid]::TryParse([string]$result.paper_id, [ref]$parsedPaperId)) {
        throw "paper_id must be a UUID"
    }
    if($result.schema -eq 'translation-result.v1' -and $result.status -eq 'succeeded'){
        foreach($role in @('translated','bilingual')){
            $artifacts=@($result.outputs.artifacts | Where-Object role -eq $role)
            if($artifacts.Count -ne 1 -or -not $artifacts[0].verified -or -not $artifacts[0].path -or $artifacts[0].sha256 -notmatch '^[a-fA-F0-9]{64}$'){
                throw "Successful translation requires one verified $role artifact with a SHA-256"
            }
        }
    }
    if($result.schema -eq 'verification-result.v1' -and $result.status -eq 'succeeded' -and -not $result.outputs.verified){throw 'Successful verification must provide verified evidence'}
    $result
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
