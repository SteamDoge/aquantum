// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use aq_application::{ImportPlan, Reader};
use aq_domain::{Gap, Id, Location};
use aq_local::{LocalBlobs, SqliteRepository, plan_import};
use clap::{Parser, Subcommand, ValueEnum};
use serde::Serialize;
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::PathBuf,
};

type App = Reader<SqliteRepository, LocalBlobs>;

#[derive(Parser)]
#[command(
    name = "aqreader",
    version,
    about = "AQuantum Reader · M0 本地核心验证客户端"
)]
struct Cli {
    /// 显式指定资料库目录；不指向原始文件夹。
    #[arg(long, global = true, default_value = ".aq-data")]
    library: PathBuf,
    #[command(subcommand)]
    command: Command,
}
#[derive(Subcommand)]
enum Command {
    /// 初始化或显示资料库身份及收件箱编号
    Init,
    /// 输出项目和书籍；个人状态、记录分别查看
    List,
    /// 创建项目，不指定父级时放入收件箱
    Project {
        name: String,
        #[arg(long)]
        parent: Option<Id>,
    },
    /// 移动项目；阻止移动到自身和后代
    MoveProject { project: Id, parent: Id },
    /// 设置漫画项目默认间隔；inherit 恢复跟随
    ProjectGap {
        project: Id,
        #[arg(value_enum)]
        gap: GapArg,
    },
    /// 生成可检查的导入计划；不会复制正文；输出文件不能已存在
    Plan {
        source: PathBuf,
        #[arg(long)]
        target: Option<Id>,
        #[arg(long)]
        output: PathBuf,
    },
    /// 确认并执行计划；相同任务可重复执行，避免重复导入
    Import {
        plan: PathBuf,
        #[arg(long)]
        skip_issues: bool,
    },
    /// 查看固定页面编号、当前顺序、间隔来源及进度
    Show { book: Id },
    /// 读取资料库内 UTF-8 TXT/Markdown 源码段落；M0 不渲染 Markdown
    Read {
        book: Id,
        #[arg(long)]
        paragraph: Option<usize>,
    },
    /// 保存页或段落进度；段落在 CLI 中从 1 开始
    Progress {
        book: Id,
        #[arg(long, conflicts_with = "page", required_unless_present = "page")]
        paragraph: Option<usize>,
        #[arg(long)]
        page: Option<Id>,
    },
    BookGap {
        book: Id,
        #[arg(value_enum)]
        gap: GapArg,
    },
    /// 反转所选页面在原槽位间的排列；未选页不变
    Reverse {
        book: Id,
        #[arg(long,value_delimiter=',',num_args=1..)]
        pages: Vec<Id>,
    },
    /// 保存关联笔记，首次保存才创建笔记内容
    Note {
        book: Id,
        text: String,
        #[arg(long, conflicts_with = "page", required_unless_present = "page")]
        paragraph: Option<usize>,
        #[arg(long)]
        page: Option<Id>,
    },
    /// 将同一书籍的关联笔记生成为标准 MD；保留可读来源锚点
    ExportNotes {
        book: Id,
        #[arg(long)]
        output: PathBuf,
    },
    /// 业务变更历史；进度不刷入操作历史
    History,
    /// 撤销页序/单书间隔修改；后续书籍版本改变时拒绝覆盖
    Undo { operation: Id },
    /// 统计正文、残留、临时副本及数据库；本阶段没有删除命令
    Storage,
}

#[derive(Clone, Copy, ValueEnum)]
enum GapArg {
    Gapped,
    Seamless,
    Inherit,
}
impl GapArg {
    fn value(self) -> Option<Gap> {
        match self {
            Self::Gapped => Some(Gap::Gapped),
            Self::Seamless => Some(Gap::Seamless),
            Self::Inherit => None,
        }
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("错误：{error}");
        std::process::exit(1);
    }
}
fn print(value: &impl Serialize) -> Result<(), Box<dyn std::error::Error>> {
    println!("{}", serde_json::to_string_pretty(value)?);
    Ok(())
}
fn write_new(path: &PathBuf, bytes: &[u8]) -> Result<(), Box<dyn std::error::Error>> {
    let mut f = OpenOptions::new().write(true).create_new(true).open(path)?;
    f.write_all(bytes)?;
    f.sync_all()?;
    Ok(())
}
fn location(
    paragraph: Option<usize>,
    page: Option<Id>,
) -> Result<Location, Box<dyn std::error::Error>> {
    match (paragraph, page) {
        (Some(n), None) if n > 0 => Ok(Location::Paragraph { index: n - 1 }),
        (None, Some(page)) => Ok(Location::Page { page }),
        _ => Err("必须提供大于 0 的段落序号，或稳定页面编号".into()),
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    let mut app = App {
        repository: SqliteRepository::open(&cli.library)?,
        blobs: LocalBlobs::open(&cli.library)?,
    };
    match cli.command {
        Command::Init => {
            let c = app.catalog()?;
            print(
                &serde_json::json!({"library":fs::canonicalize(&cli.library)?,"identity":c.id,"actor":c.actor,"inbox":c.inbox,"schema_version":c.schema_version,"catalog_revision":c.revision}),
            )?;
        }
        Command::List => {
            let c = app.catalog()?;
            print(&serde_json::json!({"projects":c.projects,"books":c.books}))?;
        }
        Command::Project { name, parent } => {
            let parent = parent.unwrap_or(app.catalog()?.inbox);
            print(&app.create_project(parent, &name)?)?;
        }
        Command::MoveProject { project, parent } => app.move_project(project, parent)?,
        Command::ProjectGap { project, gap } => app.set_project_gap(project, gap.value())?,
        Command::Plan {
            source,
            target,
            output,
        } => {
            let c = app.catalog()?;
            let plan = plan_import(&c, &cli.library, &source, target.unwrap_or(c.inbox))?;
            write_new(&output, &serde_json::to_vec_pretty(&plan)?)?;
            print(&plan)?;
        }
        Command::Import { plan, skip_issues } => {
            let plan: ImportPlan = serde_json::from_slice(&fs::read(plan)?)?;
            print(&app.import(&plan, skip_issues)?)?;
        }
        Command::Show { book } => {
            let c = app.catalog()?;
            let b = c.book(book)?;
            let gap = if b.format == aq_domain::Format::Comic {
                Some(c.effective_gap(book)?)
            } else {
                None
            };
            print(
                &serde_json::json!({"book":b,"effective_gap":gap,"progress":c.progress.iter().filter(|p|p.book==book && p.actor==c.actor).collect::<Vec<_>>()}),
            )?;
        }
        Command::Read { book, paragraph } => {
            let doc = app.text(book)?;
            if let Some(n) = paragraph {
                let text = n
                    .checked_sub(1)
                    .and_then(|index| doc.paragraphs.get(index))
                    .ok_or("段落不存在；序号从 1 开始")?;
                print(&serde_json::json!({"paragraph":n,"source":text}))?;
            } else {
                print(&doc)?;
            }
        }
        Command::Progress {
            book,
            paragraph,
            page,
        } => app.save_progress(book, location(paragraph, page)?)?,
        Command::BookGap { book, gap } => app.set_book_gap(book, gap.value())?,
        Command::Reverse { book, pages } => app.reverse_pages(book, &pages)?,
        Command::Note {
            book,
            text,
            paragraph,
            page,
        } => print(&app.add_note(book, location(paragraph, page)?, text)?)?,
        Command::ExportNotes { book, output } => {
            write_new(&output, app.notes_markdown(book)?.as_bytes())?
        }
        Command::History => print(&app.catalog()?.operations)?,
        Command::Undo { operation } => app.undo_book_change(operation)?,
        Command::Storage => print(&app.blobs.usage(&app.catalog()?)?)?,
    }
    Ok(())
}
