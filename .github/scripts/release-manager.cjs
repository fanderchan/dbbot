const fs = require("fs");
const path = require("path");

const OFFICIAL_SECTION_ORDER = [
  "## [Note]",
  "## [Add]",
  "## [Change]",
  "## [Fix]",
  "## [Remove]",
];

function assertTag(tag) {
  if (!/^v[0-9A-Za-z.+-]+$/.test(tag)) {
    throw new Error(`Unsupported release tag format: ${tag}`);
  }
}

function isPrerelease(tag) {
  return tag.includes("-");
}

function isOfficialRelease(tag) {
  return /^v\d+\.\d+\.\d+$/.test(tag);
}

function releaseNotePath(tag) {
  return path.join(process.cwd(), ".github", "release-notes", `${tag}.md`);
}

function readReleaseNote(tag) {
  const notePath = releaseNotePath(tag);
  if (!fs.existsSync(notePath)) {
    throw new Error(`Missing required release note file: .github/release-notes/${tag}.md`);
  }
  return fs.readFileSync(notePath, "utf8").trim();
}

function validateEnglishOnly(content, tag) {
  if (/[^\x00-\x7F]/.test(content)) {
    throw new Error(`Release note for ${tag} must be English only and ASCII-safe.`);
  }
}

function validateOfficialReleaseNote(content, tag) {
  const firstNonEmptyLine = content
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find((line) => line.length > 0);

  if (!firstNonEmptyLine || !OFFICIAL_SECTION_ORDER.includes(firstNonEmptyLine)) {
    throw new Error(
      `Official release note for ${tag} must start with one of: ${OFFICIAL_SECTION_ORDER.join(", ")}`
    );
  }

  const h2Headings = [...content.matchAll(/^## .+$/gm)].map((match) => match[0].trim());
  if (h2Headings.length === 0) {
    throw new Error(`Official release note for ${tag} must contain at least one allowed section.`);
  }

  const seen = new Set();
  let previousIndex = -1;

  for (const heading of h2Headings) {
    const currentIndex = OFFICIAL_SECTION_ORDER.indexOf(heading);
    if (currentIndex === -1) {
      throw new Error(
        `Official release note for ${tag} uses unsupported section heading: ${heading}`
      );
    }
    if (seen.has(heading)) {
      throw new Error(`Official release note for ${tag} repeats section heading: ${heading}`);
    }
    if (currentIndex < previousIndex) {
      throw new Error(
        `Official release note for ${tag} uses sections out of order. Required order: ${OFFICIAL_SECTION_ORDER.join(", ")}`
      );
    }
    seen.add(heading);
    previousIndex = currentIndex;
  }
}

async function listAllReleases(github, owner, repo) {
  return github.paginate(github.rest.repos.listReleases, {
    owner,
    repo,
    per_page: 100,
  });
}

function findReleaseByTag(releases, tag) {
  return releases.find((release) => release.tag_name === tag) || null;
}

async function tagExists(github, owner, repo, tag) {
  try {
    await github.rest.git.getRef({
      owner,
      repo,
      ref: `tags/${tag}`,
    });
    return true;
  } catch (error) {
    if (error.status === 404) {
      return false;
    }
    throw error;
  }
}

async function getPreviousOfficialReleaseTag(github, owner, repo, currentTag) {
  const releases = await listAllReleases(github, owner, repo);
  const previousOfficial = releases.find(
    (release) =>
      !release.draft &&
      !release.prerelease &&
      isOfficialRelease(release.tag_name) &&
      release.tag_name !== currentTag
  );
  return previousOfficial ? previousOfficial.tag_name : null;
}

async function getFirstCommitSha(github, owner, repo) {
  const commits = await github.paginate(github.rest.repos.listCommits, {
    owner,
    repo,
    per_page: 100,
  });

  if (commits.length === 0) {
    throw new Error("Could not determine the first commit SHA.");
  }

  return commits[commits.length - 1].sha;
}

async function buildManagedBody(github, owner, repo, tag) {
  const note = readReleaseNote(tag);
  validateEnglishOnly(note, tag);

  if (!isPrerelease(tag)) {
    validateOfficialReleaseNote(note, tag);
  }

  let compareBase = await getPreviousOfficialReleaseTag(github, owner, repo, tag);
  if (!compareBase) {
    compareBase = await getFirstCommitSha(github, owner, repo);
  }

  const compareUrl = `https://github.com/${owner}/${repo}/compare/${compareBase}...${tag}`;
  return `${note}\n\n---\nCompare: ${compareUrl}`;
}

async function upsertRelease({ github, context, core, tag }) {
  assertTag(tag);

  const owner = context.repo.owner;
  const repo = context.repo.repo;
  const body = await buildManagedBody(github, owner, repo, tag);
  const releases = await listAllReleases(github, owner, repo);
  const existing = findReleaseByTag(releases, tag);
  const prerelease = isPrerelease(tag);

  if (existing) {
    await github.rest.repos.updateRelease({
      owner,
      repo,
      release_id: existing.id,
      tag_name: tag,
      name: tag,
      body,
      draft: false,
      prerelease,
    });
    core.info(`Updated managed release for ${tag}`);
    return;
  }

  await github.rest.repos.createRelease({
    owner,
    repo,
    tag_name: tag,
    name: tag,
    body,
    draft: false,
    prerelease,
  });
  core.info(`Created managed release for ${tag}`);
}

async function syncReleasesForTags({ github, context, core, tags }) {
  const owner = context.repo.owner;
  const repo = context.repo.repo;

  for (const rawTag of tags) {
    const tag = String(rawTag || "").trim();
    if (!tag) {
      continue;
    }

    assertTag(tag);

    const exists = await tagExists(github, owner, repo, tag);
    if (!exists) {
      core.info(`Skipping ${tag}: tag does not exist in the repository.`);
      continue;
    }

    await upsertRelease({ github, context, core, tag });
  }
}

async function deleteReleaseForTag({ github, context, core, tag }) {
  assertTag(tag);

  const owner = context.repo.owner;
  const repo = context.repo.repo;
  const releases = await listAllReleases(github, owner, repo);
  const existing = findReleaseByTag(releases, tag);

  if (!existing) {
    core.info(`No release found for deleted tag ${tag}`);
    return;
  }

  await github.rest.repos.deleteRelease({
    owner,
    repo,
    release_id: existing.id,
  });
  core.info(`Deleted release for ${tag}`);
}

module.exports = {
  deleteReleaseForTag,
  syncReleasesForTags,
  upsertRelease,
};
