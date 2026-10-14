$ErrorActionPreference = "Stop"

Set-Location C:\Projects\gympro-api

# Back up the current schema and record its existing models.
$gymProSchemaPath = (Resolve-Path .\prisma\schema.prisma).Path
$gymProOriginalSchema = Get-Content -LiteralPath $gymProSchemaPath -Raw

$gymProBackupStamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$gymProBackupPath = "$gymProSchemaPath.before-b4-$gymProBackupStamp.bak"

Copy-Item -LiteralPath $gymProSchemaPath -Destination $gymProBackupPath

$gymProExistingModels = @(
    [regex]::Matches(
        $gymProOriginalSchema,
        '(?m)^\s*model\s+(\w+)\s*\{'
    ) | ForEach-Object {
        $_.Groups[1].Value
    }
)

# Use a separate temporary Prisma configuration for introspection.
$gymProConfigName = "b4-introspection-" + [guid]::NewGuid().ToString() + ".config.ts"
$gymProIntrospectionConfig = Join-Path (
    Resolve-Path .\scripts
).Path $gymProConfigName

$gymProConfigText = @'
import { defineConfig, env } from 'prisma/config';

export default defineConfig({
  schema: 'C:/Projects/gympro-api/prisma/schema.prisma',
  datasource: {
    url: env('GYMPRO_B4_INTROSPECTION_URL'),
  },
});
'@

[System.IO.File]::WriteAllText(
    $gymProIntrospectionConfig,
    $gymProConfigText,
    [System.Text.UTF8Encoding]::new($false)
)

$gymProPreviousIntrospectionUrl = [Environment]::GetEnvironmentVariable(
    "GYMPRO_B4_INTROSPECTION_URL",
    "Process"
)

try {
    # Enter the local PostgreSQL password without displaying it.
    $gymProSecurePassword = Read-Host `
        "Enter the local PostgreSQL postgres password" -AsSecureString

    $gymProPasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
        $gymProSecurePassword
    )

    try {
        $gymProPasswordText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $gymProPasswordPointer
        )

        $env:GYMPRO_B4_INTROSPECTION_URL = (
            "postgresql://postgres:" +
            [Uri]::EscapeDataString($gymProPasswordText) +
            "@localhost:5432/gympro_saas"
        )
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
            $gymProPasswordPointer
        )

        $gymProPasswordText = $null
        $gymProSecurePassword.Dispose()
    }

    & npx.cmd --no-install prisma db pull `
        --config $gymProIntrospectionConfig

    if ($LASTEXITCODE -ne 0) {
        throw "Administrator introspection failed."
    }
}
catch {
    Copy-Item -LiteralPath $gymProBackupPath `
        -Destination $gymProSchemaPath -Force

    throw "Introspection failed. Previous schema restored. $($_.Exception.Message)"
}
finally {
    [Environment]::SetEnvironmentVariable(
        "GYMPRO_B4_INTROSPECTION_URL",
        $gymProPreviousIntrospectionUrl,
        "Process"
    )

    Remove-Item -LiteralPath $gymProIntrospectionConfig `
        -Force -ErrorAction SilentlyContinue
}

# Confirm all existing models and the new models survived.
$gymProUpdatedSchema = Get-Content -LiteralPath $gymProSchemaPath -Raw

$gymProRequiredModels = @(
    $gymProExistingModels
    "members"
    "membership_plans"
    "plan_prices"
) | Sort-Object -Unique

foreach ($gymProModel in $gymProRequiredModels) {
    $gymProModelPattern = (
        '(?m)^\s*model\s+' +
        [regex]::Escape($gymProModel) +
        '\s*\{'
    )

    if ($gymProUpdatedSchema -notmatch $gymProModelPattern) {
        Copy-Item -LiteralPath $gymProBackupPath `
            -Destination $gymProSchemaPath -Force

        throw "Required model '$gymProModel' is missing. Previous schema restored."
    }
}

# Generate using the project's regular Prisma configuration.
& npx.cmd --no-install prisma generate

if ($LASTEXITCODE -ne 0) {
    throw "Prisma generation failed. Send the error output."
}

# Collect the source files required for registration implementation.
$gymProReviewFiles = @(
    $gymProSchemaPath
    "C:\Projects\gympro-api\src\prisma\prisma.module.ts"
)

foreach ($gymProFolder in @(".\src\auth", ".\src\members")) {
    if (Test-Path -LiteralPath $gymProFolder) {
        $gymProReviewFiles += @(
            Get-ChildItem -LiteralPath $gymProFolder `
                -Recurse -File -Filter "*.ts" |
                Sort-Object FullName |
                Select-Object -ExpandProperty FullName
        )
    }
}

$gymProReviewText = foreach ($gymProReviewFile in $gymProReviewFiles) {
    "FILE: $gymProReviewFile"
    Get-Content -LiteralPath $gymProReviewFile
    ""
}

$gymProReviewText |
    Set-Content -Path .\b4-code-review.txt -Encoding UTF8

# Verify that the API compiles.
& npm.cmd run build

if ($LASTEXITCODE -ne 0) {
    throw "Build failed. Send the error output and b4-code-review.txt."
}

Write-Output "PASS: Required Prisma models are present."
Write-Output "PASS: Prisma client generated."
Write-Output "PASS: API build completed."
Write-Output "Review file: C:\Projects\gympro-api\b4-code-review.txt"

notepad .\b4-code-review.txt