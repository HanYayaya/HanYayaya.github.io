[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [ValidateNotNullOrEmpty()]
  [string]$Source,

  [string]$Slug,
  [string]$Title,
  [string]$Description = "",
  [string]$Category = "随笔",
  [string[]]$Tags = @(),
  [string]$Cover,
  [string]$HugoPath,
  [string]$CommitMessage,
  [switch]$Preview,
  [switch]$Push,
  [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Preview -and $Push) {
  throw "-Preview 和 -Push 不能同时使用。请先预览，确认后再单独使用 -Push。"
}

$repoRoot = $PSScriptRoot
$postsRoot = Join-Path $repoRoot "content\posts"
$sourcePath = (Resolve-Path -LiteralPath $Source).Path

if ([IO.Path]::GetExtension($sourcePath) -ne ".md") {
  throw "源文件必须是 Markdown 文件：$sourcePath"
}

function Escape-YamlString {
  param([string]$Value)
  return $Value.Replace("\", "\\").Replace('"', '\"')
}

function Get-YamlScalar {
  param(
    [string]$Yaml,
    [string]$Key
  )

  $match = [regex]::Match($Yaml, "(?m)^$([regex]::Escape($Key))\s*:\s*(?<value>[^\r\n]+)\s*$")
  if (-not $match.Success) {
    return $null
  }

  return $match.Groups["value"].Value.Trim().Trim('"').Trim("'")
}

function Set-YamlValue {
  param(
    [string]$Yaml,
    [string]$Key,
    [string]$Value
  )

  $pattern = "(?m)^$([regex]::Escape($Key))\s*:[^\r\n]*$"
  $line = "${Key}: $Value"
  $valueRegex = [regex]::new($pattern)
  if ($valueRegex.IsMatch($Yaml)) {
    return $valueRegex.Replace($Yaml, $line, 1)
  }

  if ([string]::IsNullOrWhiteSpace($Yaml)) {
    return $line
  }

  return $Yaml.TrimEnd() + "`n" + $line
}

function Add-YamlListIfMissing {
  param(
    [string]$Yaml,
    [string]$Key,
    [string[]]$Values
  )

  if ([regex]::IsMatch($Yaml, "(?m)^$([regex]::Escape($Key))\s*:")) {
    return $Yaml
  }

  if ($Values.Count -eq 0) {
    return $Yaml.TrimEnd() + "`n${Key}: []"
  }

  $lines = @("${Key}:")
  foreach ($value in $Values) {
    $lines += "  - `"$(Escape-YamlString $value)`""
  }
  return $Yaml.TrimEnd() + "`n" + ($lines -join "`n")
}

function Convert-ToSlug {
  param([string]$Value)

  $result = $Value.Trim().ToLowerInvariant()
  $result = [regex]::Replace($result, "[^\p{L}\p{Nd}]+", "-")
  return $result.Trim("-")
}

function Find-ObsidianVaultRoot {
  param([string]$StartDirectory)

  $current = Get-Item -LiteralPath $StartDirectory
  while ($null -ne $current) {
    if (Test-Path -LiteralPath (Join-Path $current.FullName ".obsidian")) {
      return $current.FullName
    }
    $current = $current.Parent
  }

  return $StartDirectory
}

$sourceDirectory = Split-Path -Parent $sourcePath
$vaultRoot = Find-ObsidianVaultRoot $sourceDirectory
$supportedImageExtensions = @(".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".avif")
$copiedAssets = @{}

function Resolve-LocalAsset {
  param([string]$Reference)

  $cleanReference = [Uri]::UnescapeDataString($Reference.Trim().Trim('<').Trim('>'))
  if ($cleanReference -match "^(?i:https?://|data:|/)" ) {
    return $null
  }

  $cleanReference = ($cleanReference -split "[#?]", 2)[0]
  if ([string]::IsNullOrWhiteSpace($cleanReference)) {
    return $null
  }

  $relativePath = $cleanReference.Replace('/', [IO.Path]::DirectorySeparatorChar)
  $candidates = @(
    (Join-Path $sourceDirectory $relativePath),
    (Join-Path $vaultRoot $relativePath)
  ) | Select-Object -Unique

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  $leafName = [IO.Path]::GetFileName($relativePath)
  $matches = @(
    Get-ChildItem -LiteralPath $vaultRoot -Recurse -File -Filter $leafName |
      Where-Object { $_.FullName -notmatch "[\\/]\.obsidian[\\/]" }
  )

  if ($matches.Count -eq 1) {
    return $matches[0].FullName
  }
  if ($matches.Count -gt 1) {
    throw "附件名称不唯一，请在 Obsidian 中使用包含目录的路径：$Reference"
  }

  throw "找不到文章引用的本地附件：$Reference"
}

function Copy-ArticleAsset {
  param(
    [string]$Reference,
    [string]$DestinationDirectory
  )

  $assetPath = Resolve-LocalAsset $Reference
  if ($null -eq $assetPath) {
    return $null
  }

  $extension = [IO.Path]::GetExtension($assetPath).ToLowerInvariant()
  if ($supportedImageExtensions -notcontains $extension) {
    throw "暂不支持该附件格式：$assetPath"
  }

  $fileName = [IO.Path]::GetFileName($assetPath)
  if ($copiedAssets.ContainsKey($fileName) -and $copiedAssets[$fileName] -ne $assetPath) {
    throw "存在两个同名但路径不同的附件：$fileName"
  }

  Copy-Item -LiteralPath $assetPath -Destination (Join-Path $DestinationDirectory $fileName) -Force
  $copiedAssets[$fileName] = $assetPath
  return $fileName
}

function Format-MarkdownImageTarget {
  param([string]$FileName)
  return "<$FileName>"
}

function Assert-NoUnrelatedGitChanges {
  param([string]$AllowedPath)

  $statusLines = @(& git -C $repoRoot status --porcelain=v1 --untracked-files=all)
  if ($LASTEXITCODE -ne 0) {
    throw "无法读取 Git 工作区状态。"
  }

  $normalizedAllowedPath = $AllowedPath.Replace("\", "/").TrimEnd("/") + "/"
  $unrelatedChanges = @()
  foreach ($statusLine in $statusLines) {
    if ([string]::IsNullOrWhiteSpace($statusLine)) {
      continue
    }

    $changedPath = $statusLine.Substring(3).Trim()
    if ($changedPath.Contains(" -> ")) {
      $changedPath = ($changedPath -split " -> ", 2)[1]
    }
    $changedPath = $changedPath.Trim('"').Replace("\", "/")
    if (-not $changedPath.StartsWith($normalizedAllowedPath, [StringComparison]::OrdinalIgnoreCase)) {
      $unrelatedChanges += $statusLine
    }
  }

  if ($unrelatedChanges.Count -gt 0) {
    $details = $unrelatedChanges -join "`n"
    throw "检测到目标文章目录之外的未提交改动。为避免误提交，请先处理这些文件：`n$details"
  }
}

$utf8 = New-Object Text.UTF8Encoding($false)
$rawContent = [IO.File]::ReadAllText($sourcePath, $utf8)
$frontMatterMatch = [regex]::Match(
  $rawContent,
  "\A---\s*\r?\n(?<yaml>.*?)\r?\n---\s*(?:\r?\n)?",
  [Text.RegularExpressions.RegexOptions]::Singleline
)

if ($frontMatterMatch.Success) {
  $yaml = $frontMatterMatch.Groups["yaml"].Value.Trim()
  $body = $rawContent.Substring($frontMatterMatch.Length)
} else {
  $yaml = ""
  $body = $rawContent
}

$resolvedTitle = $Title
if ([string]::IsNullOrWhiteSpace($resolvedTitle)) {
  $resolvedTitle = Get-YamlScalar $yaml "title"
}
if ([string]::IsNullOrWhiteSpace($resolvedTitle)) {
  $resolvedTitle = [IO.Path]::GetFileNameWithoutExtension($sourcePath)
}

$resolvedSlug = $Slug
if ([string]::IsNullOrWhiteSpace($resolvedSlug)) {
  $resolvedSlug = Get-YamlScalar $yaml "slug"
}
if ([string]::IsNullOrWhiteSpace($resolvedSlug)) {
  $resolvedSlug = Convert-ToSlug ([IO.Path]::GetFileNameWithoutExtension($sourcePath))
} else {
  $resolvedSlug = Convert-ToSlug $resolvedSlug
}
if ([string]::IsNullOrWhiteSpace($resolvedSlug)) {
  throw "无法自动生成 slug，请通过 -Slug 指定，例如：-Slug my-first-post"
}

$yaml = Set-YamlValue $yaml "title" "`"$(Escape-YamlString $resolvedTitle)`""
$yaml = Set-YamlValue $yaml "slug" "`"$(Escape-YamlString $resolvedSlug)`""
if ($null -eq (Get-YamlScalar $yaml "date")) {
  $yaml = Set-YamlValue $yaml "date" ([DateTimeOffset]::Now.ToString("yyyy-MM-ddTHH:mm:sszzz"))
}
if ($null -eq (Get-YamlScalar $yaml "description")) {
  $yaml = Set-YamlValue $yaml "description" "`"$(Escape-YamlString $Description)`""
}
$yaml = Add-YamlListIfMissing $yaml "categories" @($Category)
$yaml = Add-YamlListIfMissing $yaml "tags" $Tags
$yaml = Set-YamlValue $yaml "draft" "false"
if ($null -eq (Get-YamlScalar $yaml "toc")) {
  $yaml = Set-YamlValue $yaml "toc" "true"
}
if (-not [string]::IsNullOrWhiteSpace($Cover)) {
  $yaml = Set-YamlValue $yaml "cover" "`"$(Escape-YamlString $Cover)`""
}

$targetDirectory = Join-Path $postsRoot $resolvedSlug
if ($Push) {
  Assert-NoUnrelatedGitChanges "content/posts/$resolvedSlug"
}
if ((Test-Path -LiteralPath $targetDirectory) -and -not $Force) {
  throw "目标文章已存在：$targetDirectory`n如需更新，请重新运行并添加 -Force。"
}
New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null

$lineEnding = if ($rawContent.Contains("`r`n")) { "`r`n" } else { "`n" }
$lines = [regex]::Split($body, "\r?\n")
$convertedLines = New-Object Collections.Generic.List[string]
$insideFence = $false

foreach ($line in $lines) {
  if ($line -match "^\s*(```|~~~)") {
    $insideFence = -not $insideFence
    $convertedLines.Add($line)
    continue
  }

  if ($insideFence) {
    $convertedLines.Add($line)
    continue
  }

  $convertedLine = [regex]::Replace(
    $line,
    '!\[(?<alt>[^\]]*)\]\((?<target><[^>]+>|[^\s\)]+)(?<title>\s+["''][^"'']*["''])?\)',
    [Text.RegularExpressions.MatchEvaluator]{
      param($match)
      $target = $match.Groups["target"].Value.Trim('<').Trim('>')
      if ($target -match "^(?i:https?://|data:|/)" ) {
        return $match.Value
      }
      $copiedName = Copy-ArticleAsset $target $targetDirectory
      $formattedTarget = Format-MarkdownImageTarget $copiedName
      return "![$($match.Groups['alt'].Value)]($formattedTarget$($match.Groups['title'].Value))"
    }
  )

  $convertedLine = [regex]::Replace(
    $convertedLine,
    '!\[\[(?<target>[^\]|]+)(?:\|(?<option>[^\]]+))?\]\]',
    [Text.RegularExpressions.MatchEvaluator]{
      param($match)
      $target = $match.Groups["target"].Value.Trim()
      $option = $match.Groups["option"].Value.Trim()
      $alt = [IO.Path]::GetFileNameWithoutExtension($target)
      if (-not [string]::IsNullOrWhiteSpace($option) -and $option -notmatch "^\d+(?:x\d+)?$") {
        $alt = $option
      }
      $copiedName = Copy-ArticleAsset $target $targetDirectory
      return "![$alt]($(Format-MarkdownImageTarget $copiedName))"
    }
  )

  $convertedLines.Add($convertedLine)
}

$convertedBody = $convertedLines -join $lineEnding
if ([regex]::IsMatch($convertedBody, '(?<!\!)\[\[[^\]]+\]\]')) {
  Write-Warning "文章仍包含 Obsidian 双向链接 [[...]]。Hugo 不会自动解析，请检查生成的 index.md。"
}

$coverReference = Get-YamlScalar $yaml "cover"
if (-not [string]::IsNullOrWhiteSpace($coverReference)) {
  $copiedCover = Copy-ArticleAsset $coverReference $targetDirectory
  if ($null -ne $copiedCover) {
    $yaml = Set-YamlValue $yaml "cover" "`"$(Escape-YamlString $copiedCover)`""
  }
}

$targetMarkdown = Join-Path $targetDirectory "index.md"
$finalContent = "---$lineEnding$($yaml.Trim())$lineEnding---$lineEnding$lineEnding$convertedBody"
[IO.File]::WriteAllText($targetMarkdown, $finalContent, $utf8)

function Resolve-HugoExecutable {
  if (-not [string]::IsNullOrWhiteSpace($HugoPath)) {
    return (Resolve-Path -LiteralPath $HugoPath).Path
  }
  if (-not [string]::IsNullOrWhiteSpace($env:HUGO_PATH)) {
    return (Resolve-Path -LiteralPath $env:HUGO_PATH).Path
  }

  $command = Get-Command hugo -ErrorAction SilentlyContinue
  if ($null -ne $command) {
    return $command.Source
  }

  throw "找不到 Hugo。请安装 Hugo Extended，或通过 -HugoPath 指定 hugo.exe。"
}

$hugo = Resolve-HugoExecutable
$env:HUGO_CACHEDIR = Join-Path ([IO.Path]::GetTempPath()) "hanyayaya-hugo-cache"
& $hugo --source $repoRoot --gc --minify
if ($LASTEXITCODE -ne 0) {
  throw "Hugo 构建失败，文章尚未发布。"
}

Write-Host ""
Write-Host "文章已准备完成：$targetMarkdown" -ForegroundColor Green
Write-Host "文章地址：/posts/$resolvedSlug/"
Write-Host "复制图片：$($copiedAssets.Count) 张"

if ($Push) {
  $branch = (& git -C $repoRoot branch --show-current).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw "无法读取 Git 分支。"
  }
  if ($branch -ne "main") {
    throw "自动部署只监听 main 分支，当前分支为：$branch"
  }

  $relativeArticlePath = "content/posts/$resolvedSlug"
  & git -C $repoRoot add -- $relativeArticlePath
  if ($LASTEXITCODE -ne 0) {
    throw "git add 失败。"
  }

  if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
    $CommitMessage = "Publish: $resolvedTitle"
  }

  & git -C $repoRoot commit -m $CommitMessage
  if ($LASTEXITCODE -ne 0) {
    throw "git commit 失败，可能没有可提交的内容。"
  }

  & git -C $repoRoot push origin main
  if ($LASTEXITCODE -ne 0) {
    throw "git push 失败。"
  }

  Write-Host "文章已推送，GitHub Actions 将自动部署。" -ForegroundColor Green
} elseif ($Preview) {
  Write-Host "启动本地预览，按 Ctrl+C 停止。" -ForegroundColor Cyan
  & $hugo server --source $repoRoot -D
} else {
  Write-Host ""
  Write-Host "下一步：" -ForegroundColor Cyan
  Write-Host "  本地预览：.\publish.ps1 -Source `"$sourcePath`" -Slug `"$resolvedSlug`" -Force -Preview"
  Write-Host "  正式发布：.\publish.ps1 -Source `"$sourcePath`" -Slug `"$resolvedSlug`" -Force -Push"
}
