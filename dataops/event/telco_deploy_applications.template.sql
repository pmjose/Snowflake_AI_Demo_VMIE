-- ============================================================================
-- Virgin Media Ireland AI Demo - Deploy Applications (DataOps Template)
-- ============================================================================
-- Description: Deploys stored procedures, functions, and Intelligence Agent
-- Variables: {{ DATABASE_NAME }}, {{ WAREHOUSE_NAME }}, {{ SCHEMA_NAME }}
-- ============================================================================

USE ROLE {{ env.EVENT_ATTENDEE_ROLE | default('TELCO_ANALYST_ROLE') }};
USE WAREHOUSE {{ env.EVENT_WAREHOUSE | default('VMIE_DEMO_WH') }};
USE DATABASE {{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }};
USE SCHEMA {{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }};

-- ============================================================================
-- Step 1: Create Stored Procedure for Presigned URLs
-- ============================================================================

CREATE OR REPLACE PROCEDURE Get_File_Presigned_URL_SP(
    RELATIVE_FILE_PATH STRING, 
    EXPIRATION_MINS INTEGER DEFAULT 60
)
RETURNS STRING
LANGUAGE SQL
COMMENT = 'Generates a presigned URL for a file in the static @DATA_STAGE. Input is the relative file path.'
EXECUTE AS CALLER
AS
$$
DECLARE
    presigned_url STRING;
    sql_stmt STRING;
    expiration_seconds INTEGER;
        stage_name STRING DEFAULT '@{{ env.EVENT_DATABASE | default("VIRGIN_MEDIA_IE_AI_DEMO") }}.{{ env.EVENT_SCHEMA | default("VIRGIN_MEDIA_IE_SCHEMA") }}.DATA_STAGE';
BEGIN
    expiration_seconds := EXPIRATION_MINS * 60;

    sql_stmt := 'SELECT GET_PRESIGNED_URL(' || stage_name || ', ' || '''' || RELATIVE_FILE_PATH || '''' || ', ' || expiration_seconds || ') AS url';
    
    EXECUTE IMMEDIATE :sql_stmt;
    
    SELECT "URL"
    INTO :presigned_url
    FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
    
    RETURN :presigned_url;
END;
$$;

-- ============================================================================
-- Step 2: Create Stored Procedure for Sending Emails
-- ============================================================================

CREATE OR REPLACE PROCEDURE send_mail(recipient TEXT, subject TEXT, text TEXT)
RETURNS TEXT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'send_mail'
AS
$$
def send_mail(session, recipient, subject, text):
    session.call(
        'SYSTEM$SEND_EMAIL',
        'cityfibre_email_int',
        recipient,
        subject,
        text,
        'text/html'
    )
    return f'Email was sent to {recipient} with subject: "{subject}".'
$$;

-- ============================================================================
-- Step 3: Create Web Scraping Function
-- ============================================================================

CREATE OR REPLACE FUNCTION Web_scrape(weburl STRING)
RETURNS STRING
LANGUAGE PYTHON
RUNTIME_VERSION = 3.11
HANDLER = 'get_page'
EXTERNAL_ACCESS_INTEGRATIONS = (cityfibre_external_access_integration)
PACKAGES = ('requests', 'beautifulsoup4')
AS
$$
import _snowflake
import requests
from bs4 import BeautifulSoup

def get_page(weburl):
  url = f"{weburl}"
  response = requests.get(url)
  soup = BeautifulSoup(response.text)
  return soup.get_text()
$$;

-- ============================================================================
-- Step 4: Create Streamlit App Generator Procedure
-- ============================================================================

CREATE OR REPLACE PROCEDURE GENERATE_STREAMLIT_APP("USER_INPUT" VARCHAR)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python')
HANDLER = 'generate_app'
EXECUTE AS OWNER
AS '
def generate_app(session, user_input):
    import re
    import tempfile
    import os
    
    # Build the prompt for AI_COMPLETE
    prompt = f"""Generate a Streamlit in Snowflake code that has an existing session. 
- Output should only contain the code and nothing else. 

- Total number of characters in the entire python code should be less than 32000 chars

- create session object like this: 
from snowflake.snowpark.context import get_active_session
session = get_active_session()

- Never CREATE, DROP , TRUNCATE OR ALTER  tables. You are only allowed to use SQL SELECT statements.

- Use only native Streamlit visualizations and no html formatting

- ignore & remove VERTICAL=''Retail'' filter in all source SQL queries.

- Use ONLY SQL queries provided in the input as the data source for all dataframes placing them into CTE to generate new ones. You can remove LIMIT or modify WHERE clauses to remove or modify filters. Example:

WITH cte AS (
    SELECT original_query_from_prompt modified 
    WHERE x=1 --this portion can be removed or modified
    LIMIT 5   -- this needs to be removed
)
SELECT *
FROM cte as new_query for dataframe;


- DO NOT use any table or column other than what was listed in the source queries below. 

- all table column names should be in UPPER CASE

- Include filters for users such as for dates ranges & all dimensions discussed within the user conversation to make it more interactive. Queries used for user selections using distinct values should not use any filters for VERTICAL = RETAIL.

- Can have up to 2 tabs. Each tab can have up maximum 4 visualizatons (chart & kpis)

- Use only native Streamlit visualizations and no html formatting. 

- For Barcharts showing Metric by Dimension_Name, bars should be sorted from highest metric value to lowest . 

- dont use st.Scatter_chart, st.bokeh_chart, st.set_page_config The page_title, page_icon, and menu_items properties of the st.set_page_config command are not supported. 

- Dont use plotly. 

- When generating code that involves loading data from a SQL source (like Snowflake/Snowpark)
into a Pandas DataFrame for use in a visualization library (like Streamlit), you must explicitly ensure all date and timestamp columns are correctly cast as Pandas datetime objects.

Specific Steps:

Identify all columns derived from SQL date/timestamp functions (e.g., DATE, MONTH, SALE_DATE).

Immediately after calling the .to_pandas() method to load the data into the DataFrame df, insert code to apply pd.to_datetime() to these column

- App should perform the following:
<input>
{user_input}
</input>"""
    
    # Escape single quotes for SQL
    escaped_prompt = prompt.replace("''", "''''")
    
    # Build model_parameters as a separate string to avoid f-string escaping issues
    model_params = "{''temperature'': 0, ''max_tokens'': 8192}"
    
    # Execute AI_COMPLETE query with model parameters
    query = f"""SELECT AI_COMPLETE(model => ''claude-4-sonnet'',
                                prompt => ''{escaped_prompt}'',
                                model_parameters => {model_params}
                                )::string as result"""
    
    result = session.sql(query).collect()
    
    if result and len(result) > 0:
        code_response = result[0][''RESULT'']
        
        # Strip markdown code block markers using regex
        cleaned_code = code_response.strip()
        
        # Remove ```python, ```, or ```py markers at start
        cleaned_code = re.sub(r''^```(?:python|py)?\\s*\\n?'', '''', cleaned_code)
        # Remove ``` at end
        cleaned_code = re.sub(r''\\n?```\\s*$'', '''', cleaned_code)
        
        # Remove any leading/trailing whitespace
        cleaned_code = cleaned_code.strip()
        
        # Prepare environment.yml content
        environment_yml_content = """# Snowflake environment file for Streamlit in Snowflake (SiS)
# This file specifies Python package dependencies for your Streamlit app

name: streamlit_app_env
channels:
  - snowflake

dependencies:
  - plotly=6.3.0
"""
        
        # Write files to temporary directory
        temp_dir = tempfile.gettempdir()
        temp_py_file = os.path.join(temp_dir, ''test.py'')
        temp_yml_file = os.path.join(temp_dir, ''environment.yml'')
        
        try:
            # Write the Python code to temporary file
            with open(temp_py_file, ''w'') as f:
                f.write(cleaned_code)
            
            # Write the environment.yml to temporary file
            with open(temp_yml_file, ''w'') as f:
                f.write(environment_yml_content)
            
            # Upload both files to Snowflake stage
            stage_path = ''@DATA_STAGE''
            
            # Upload Python file
            session.file.put(
                temp_py_file,
                stage_path,
                auto_compress=False,
                overwrite=True
            )
            
            # Upload environment.yml file
            session.file.put(
                temp_yml_file,
                stage_path,
                auto_compress=False,
                overwrite=True
            )
            
            # Clean up temporary files
            os.remove(temp_py_file)
            os.remove(temp_yml_file)
            
            # Create Streamlit app
            app_name = ''AUTO_GENERATED_1''
            warehouse = ''{{ env.EVENT_WAREHOUSE | default("VMIE_DEMO_WH") }}''
            
            create_streamlit_sql = f"""
            CREATE OR REPLACE STREAMLIT {{ env.EVENT_DATABASE | default("VIRGIN_MEDIA_IE_AI_DEMO") }}.{{ env.EVENT_SCHEMA | default("VIRGIN_MEDIA_IE_SCHEMA") }}.{app_name}
                FROM @DATA_STAGE
                MAIN_FILE = ''test.py''
                QUERY_WAREHOUSE = {warehouse}
            """
            
            try:
                session.sql(create_streamlit_sql).collect()
                
                # Get account information for URL
                account_info = session.sql("SELECT CURRENT_ACCOUNT_NAME() AS account, CURRENT_ORGANIZATION_NAME() AS org").collect()
                account_name = account_info[0][''ACCOUNT'']
                org_name = account_info[0][''ORG'']
                
                # Construct app URL
                app_url = f"https://app.snowflake.com/{org_name}/{account_name}/#/streamlit-apps/{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.{app_name}"
                
                # Return only the URL if successful
                return app_url
                
            except Exception as create_error:
                return f"""Files saved to {stage_path}/
   - test.py
   - environment.yml

Warning: Could not auto-create Streamlit app: {str(create_error)}

To create manually, run:
CREATE OR REPLACE STREAMLIT {{ env.EVENT_DATABASE | default("VIRGIN_MEDIA_IE_AI_DEMO") }}.{{ env.EVENT_SCHEMA | default("VIRGIN_MEDIA_IE_SCHEMA") }}.{app_name}
    FROM @DATA_STAGE
    MAIN_FILE = ''test.py''
    QUERY_WAREHOUSE = {warehouse};

--- Generated Code ---
{cleaned_code}"""
            
        except Exception as e:
            # Clean up temp files if they exist
            if os.path.exists(temp_py_file):
                os.remove(temp_py_file)
            if os.path.exists(temp_yml_file):
                os.remove(temp_yml_file)
            return f"Error saving to stage: {str(e)}\\n\\n--- Generated Code ---\\n{cleaned_code}"
    else:
        return "Error: No response from AI_COMPLETE"
';

-- ============================================================================
-- Step 5: Create Snowflake Intelligence Agent
-- ============================================================================

CREATE OR REPLACE AGENT {{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.VirginMediaIE_Executive_Agent
WITH PROFILE='{ "display_name": "Virgin Media Ireland Executive Agent" }'
    COMMENT=$$ Virgin Media Ireland executive intelligence agent for C-level leaders (CEO, CFO, CMO, COO/CTO). Covers fibre rollout, broadband/TV/mobile bundle performance, business connectivity, partner offers, ARR/MRR, NPS, campaigns, and Irish market analysis. All figures in euros (€). $$
FROM SPECIFICATION $$
{
  "models": {
    "orchestration": ""
  },
  "instructions": {
    "response": "You are a business intelligence analyst for Virgin Media Ireland, the leading connected entertainment and communications provider in Ireland (part of Liberty Global). You have access to fibre rollout metrics, broadband/TV/mobile bundle performance, financial results, marketing campaigns, HR information, and network reliability data. All monetary values are in euros (€). Customer and market segments include residential households, mobile SIM-only customers, business connectivity, public sector sites, and wholesale/partner access. Network coverage spans Ireland (Dublin, Cork, Limerick, Galway, Waterford, Midlands, North West, and other towns) with multi-gigabit full-fibre rollout targeting speeds up to 5Gb and strong in-home WiFi via WiFi Guarantee.\n\n**IMPORTANT GUARDRAILS:**\n- You MUST ONLY answer questions related to Virgin Media Ireland business data, including fibre build, broadband/TV/mobile performance, finance, marketing, HR, network infrastructure, and competitive analysis in Ireland.\n- You MUST NOT answer general knowledge questions, trivia, current events, politics, celebrities, sports, or any topic not directly related to Virgin Media Ireland's business operations.\n- If asked about unrelated topics, politely decline and redirect: 'I can only help with questions about Virgin Media Ireland data. You can ask about fibre rollout, bundle take-up, network reliability, partner performance, or competitive positioning in Ireland.'\n- Never use external knowledge to answer questions - only use the data and documents available through your tools.",
    "orchestration": "Use cortex search for finance and strategy documents, network infrastructure details, and competitive analysis. Use cortex analyst for structured data queries on fibre rollout, sales, revenue, campaigns, HR, and operations.\n\n**GUARDRAIL CHECK:** Before processing ANY query, first determine if it relates to Virgin Media Ireland business data. If the query is about general knowledge, current events, politics, entertainment, or any topic NOT related to Virgin Media Ireland's build, sales, finance, marketing, HR, network infrastructure, strategy, or competitive landscape - DO NOT use any tools and instead respond with a polite redirect to business-related questions.\n\nFor Sales Datamart: Contains broadband/TV/mobile bundle sales, take-up across households, SMEs, and public sector, WiFi Guarantee adoption, and partner/wholesale access. Regions include Dublin, Cork, Limerick, Galway, Waterford, Midlands, and national backbone metrics.\n\nFor Marketing Datamart: Campaigns include broadband-first bundles, TV/entertainment promotions, SIM cross-sell, and WiFi Guarantee awareness. Channels include digital, TV, retail/field, and partner-led campaigns.\n\nFor Strategy Documents: Search for market position, investment focus for fibre upgrades, ESG commitments, Liberty Global alignment, and board-ready narratives.\n\nFor Network Infrastructure (use 'Search Internal Documents: Network' tool): When users ask about premises ready for service, uptime, latency/jitter, backhaul capacity, or resilience, ALWAYS use the Network search tool.",
    "sample_questions": [
      {
        "question": "How many premises are fibre-ready by region (Dublin, Cork, Galway, Limerick) and what is take-up?"
      },
      {
        "question": "What is broadband + TV bundle penetration and WiFi Guarantee adoption by region?"
      },
      {
        "question": "Summarize fibre upgrade investment and its impact on 5Gb rollout and reliability."
      },
      {
        "question": "What are our top revenue-generating broadband, TV, mobile, and business connectivity products?"
      },
      {
        "question": "Show network uptime, latency, and resilience for the Irish footprint."
      },
      {
        "question": "How many public sector and smart city sites are connected and what is their NPS?"
      },
      {
        "question": "How are net adds and churn trending quarter over quarter?"
      }
    ]
  },
  "tools": [
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "Query Finance Datamart",
        "description": "Query Virgin Media Ireland financial data: fibre capex, revenue by broadband/TV/mobile/business category, partner economics, vendor spend (network build, CPE/WiFi, cloud), expenses, and department costs. All amounts in euros (€)."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "Query Sales Datamart",
        "description": "Query Virgin Media Ireland sales and take-up data: by segment (Homes/SMB/Enterprise/Public Sector/Partner/Mobile), industry, products (Broadband & WiFi, Broadband + TV bundles, Mobile SIMs, Business Internet & Ethernet, Backbone/Dark Fibre, Partner Access, Smart City & Public Sector, Managed Services), Irish regions (Dublin, Cork, Limerick, Galway, Waterford, Midlands, North West), and revenue in euros. Use for revenue analysis, top customers, partner performance, bundle adoption, and WiFi Guarantee uptake."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "Query HR Datamart",
        "description": "Query Virgin Media Ireland workforce data: employees, departments, jobs, channel account managers, salaries, and attrition."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "Query Marketing Datamart",
        "description": "Query Virgin Media Ireland marketing data: campaigns (Broadband-first bundles, WiFi Guarantee, TV/entertainment, SIM cross-sell), channels (Digital, TV, Retail/Field, Partners), spend, impressions, leads, and ROI. Use for campaign effectiveness and partner marketing analysis."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "Query KPI Datamart",
        "description": "Query Virgin Media Ireland KPI and subscriber metrics: broadband, TV, voice, mobile (MVNO) totals, city-level subs, WiFi Guarantee, and 5G penetration."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "Query B2C Subscriptions",
        "description": "Query Virgin Media Ireland B2C customers and subscriptions: broadband/TV/mobile bundles, SIM counts, WiFi guarantee adoption, and EUR monthly fees."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_analyst_text_to_sql",
        "name": "Query B2B Summary",
        "description": "Query Virgin Media Ireland B2B/B2G revenue and units by customer, product, and region."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "Search Internal Documents: Finance",
        "description": "Search Virgin Media Ireland finance documents: high-level accounts, fibre investment summaries, ARPU/ARPA analysis, unit economics, partner revenue mix, ESG notes, and vendor contracts."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "Search Internal Documents: HR",
        "description": "Search HR documents: employee handbook, performance guidelines, department structures, and workforce policies."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "Search Internal Documents: Sales",
        "description": "Search Virgin Media Ireland sales documents: partner playbooks, bundle take-up reports, wholesale ISP onboarding guides, and customer success stories. Includes positioning vs eir, Sky, and regional fibre altnets."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "Search Internal Documents: Marketing",
        "description": "Search marketing documents including campaign strategies, competitive analysis, NPS reports, and ROI analysis."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "Search Internal Documents: Strategy",
        "description": "Search CEO/strategy documents including fibre rollout roadmaps, investment summaries, market position analysis vs eir/Sky/altnets, investor relations FAQs, board presentations, ESG reports, and ComReg-related compliance themes."
      }
    },
    {
      "tool_spec": {
        "type": "cortex_search",
        "name": "Search Internal Documents: Network",
        "description": "Search network infrastructure documents including fibre footprint coverage (premises passed and ready for service), platform uptime, carrier/backhaul connections, latency/jitter, resilience, smart city backhaul, and network redundancy."
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "Web_scraper",
        "description": "This tool should be used if the user wants to analyse contents of a given web page. This tool will use a web url (https or https) as input and will return the text content of that web page for further analysis",
        "input_schema": {
          "type": "object",
          "properties": {
            "weburl": {
              "description": "Agent should ask web url ( that includes http:// or https:// ). It will scrape text from the given url and return as a result.",
              "type": "string"
            }
          },
          "required": [
            "weburl"
          ]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "Send_Emails",
        "description": "This tool is used to send emails to a email recipient. It can take an email, subject & content as input to send the email. Always use HTML formatted content for the emails.",
        "input_schema": {
          "type": "object",
          "properties": {
            "recipient": {
              "description": "recipient of email",
              "type": "string"
            },
            "subject": {
              "description": "subject of email",
              "type": "string"
            },
            "text": {
              "description": "content of email",
              "type": "string"
            }
          },
          "required": [
            "text",
            "recipient",
            "subject"
          ]
        }
      }
    },
    {
      "tool_spec": {
        "type": "generic",
        "name": "Dynamic_Doc_URL_Tool",
        "description": "This tools uses the ID Column coming from Cortex Search tools for reference docs and returns a temp URL for users to view & download the docs.\n\nReturned URL should be presented as a HTML Hyperlink where doc title should be the text and out of this tool should be the url.\n\nURL format for PDF docs that are are like this which has no PDF in the url. Create the Hyperlink format so the PDF doc opens up in a browser instead of downloading the file.\nhttps://domain/path/unique_guid",
        "input_schema": {
          "type": "object",
          "properties": {
            "expiration_mins": {
              "description": "default should be 5",
              "type": "number"
            },
            "relative_file_path": {
              "description": "This is the ID Column value Coming from Cortex Search tool.",
              "type": "string"
            }
          },
          "required": [
            "expiration_mins",
            "relative_file_path"
          ]
        }
      }
    }
  ],
  "tool_resources": {
    "Dynamic_Doc_URL_Tool": {
      "execution_environment": {
        "query_timeout": 0,
        "type": "warehouse",
        "warehouse": "{{ env.EVENT_WAREHOUSE | default('VMIE_DEMO_WH') }}"
      },
      "identifier": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.GET_FILE_PRESIGNED_URL_SP",
      "name": "GET_FILE_PRESIGNED_URL_SP(VARCHAR, DEFAULT NUMBER)",
      "type": "procedure"
    },
    "Query Finance Datamart": {
      "semantic_view": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.FINANCE_SEMANTIC_VIEW"
    },
    "Query HR Datamart": {
      "semantic_view": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.HR_SEMANTIC_VIEW"
    },
    "Query Marketing Datamart": {
      "semantic_view": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.MARKETING_SEMANTIC_VIEW"
    },
    "Query Sales Datamart": {
      "semantic_view": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.SALES_SEMANTIC_VIEW"
    },
    "Query KPI Datamart": {
      "semantic_view": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.KPI_SEMANTIC_VIEW"
    },
    "Query B2C Subscriptions": {
      "semantic_view": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.B2C_SUBS_SEMANTIC_VIEW"
    },
    "Query B2B Summary": {
      "semantic_view": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.B2B_SUMMARY_SEMANTIC_VIEW"
    },
    "Search Internal Documents: Finance": {
      "id_column": "FILE_URL",
      "max_results": 5,
      "name": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.SEARCH_FINANCE_DOCS",
      "title_column": "TITLE"
    },
    "Search Internal Documents: HR": {
      "id_column": "FILE_URL",
      "max_results": 5,
      "name": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.SEARCH_HR_DOCS",
      "title_column": "TITLE"
    },
    "Search Internal Documents: Marketing": {
      "id_column": "RELATIVE_PATH",
      "max_results": 5,
      "name": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.SEARCH_MARKETING_DOCS",
      "title_column": "TITLE"
    },
    "Search Internal Documents: Sales": {
      "id_column": "FILE_URL",
      "max_results": 5,
      "name": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.SEARCH_SALES_DOCS",
      "title_column": "TITLE"
    },
    "Search Internal Documents: Strategy": {
      "id_column": "RELATIVE_PATH",
      "max_results": 5,
      "name": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.SEARCH_STRATEGY_DOCS",
      "title_column": "TITLE"
    },
    "Search Internal Documents: Network": {
      "id_column": "RELATIVE_PATH",
      "max_results": 5,
      "name": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.SEARCH_NETWORK_DOCS",
      "title_column": "TITLE"
    },
    "Send_Emails": {
      "execution_environment": {
        "query_timeout": 0,
        "type": "warehouse",
        "warehouse": "{{ env.EVENT_WAREHOUSE | default('VMIE_DEMO_WH') }}"
      },
      "identifier": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.SEND_MAIL",
      "name": "SEND_MAIL(VARCHAR, VARCHAR, VARCHAR)",
      "type": "procedure"
    },
    "Web_scraper": {
      "execution_environment": {
        "query_timeout": 0,
        "type": "warehouse",
        "warehouse": "{{ env.EVENT_WAREHOUSE | default('VMIE_DEMO_WH') }}"
      },
      "identifier": "{{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.WEB_SCRAPE",
      "name": "WEB_SCRAPE(VARCHAR)",
      "type": "function"
    }
  }
}
$$;

-- ============================================================================
-- Grant Agent Access to Users
-- ============================================================================

-- Grant USAGE on the agent to the analyst role (CEO, CFO, CRO users have this role)
GRANT USAGE ON AGENT {{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.VirginMediaIE_Executive_Agent 
    TO ROLE {{ env.EVENT_ATTENDEE_ROLE | default('TELCO_ANALYST_ROLE') }};

-- Also grant to ACCOUNTADMIN for admin access
GRANT USAGE ON AGENT {{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.VirginMediaIE_Executive_Agent 
    TO ROLE ACCOUNTADMIN;

-- Grant to PUBLIC for broader access (optional - remove if you want restricted access)
GRANT USAGE ON AGENT {{ env.EVENT_DATABASE | default('VIRGIN_MEDIA_IE_AI_DEMO') }}.{{ env.EVENT_SCHEMA | default('VIRGIN_MEDIA_IE_SCHEMA') }}.VirginMediaIE_Executive_Agent 
    TO ROLE PUBLIC;

-- ============================================================================
-- Verification
-- ============================================================================

SELECT 'Virgin Media Ireland AI Demo applications deployed successfully!' AS status,
       'Procedures: Get_File_Presigned_URL_SP, send_mail, Web_scrape, GENERATE_STREAMLIT_APP' AS procedures_created,
       'Agent: {{ env.EVENT_DATABASE | default("VIRGIN_MEDIA_IE_AI_DEMO") }}.{{ env.EVENT_SCHEMA | default("VIRGIN_MEDIA_IE_SCHEMA") }}.VirginMediaIE_Executive_Agent' AS agent_created,
       CURRENT_TIMESTAMP() AS deployed_at;
