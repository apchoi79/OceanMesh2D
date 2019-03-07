classdef meshgen
    %   MESHGEN: Mesh generation class
    %   Handles input parameters to create a meshgen class object that can be
    %   used to build a msh class.
    %   Copyright (C) 2018  Keith Roberts & William Pringle
    %
    %   This program is free software: you can redistribute it and/or modify
    %   it under the terms of the GNU General Public License as published by
    %   the Free Software Foundation, either version 3 of the License, or
    %   (at your option) any later version.
    %
    %   This program is distributed in the hope that it will be useful,
    %   but WITHOUT ANY WARRANTY; without even the implied warranty of
    %   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    %   GNU General Public License for more details.
    %
    %   You should have received a copy of the GNU General Public License
    %   along with this program.  If not, see <http://www.gnu.org/licenses/>.
    properties
        fd            % handle to distance function
        fh            % handle to edge function
        h0            % minimum edge length
        edgefx        % edgefx class
        bbox          % bounding box [xmin,ymin; xmax,ymax]
        pfix          % fixed node positions (nfix x 2 )
        egfix         % edge constraints
        plot_on       % flag to plot (def: 1) or not (0)
        nscreen       % how many it to plot and write temp files (def: 5)
        bou           % geodata class
        ef            % edgefx class
        itmax         % maximum number of iterations.
        outer         % meshing boundary
        inner         % island boundaries      
        mainland      % the shoreline boundary 
        boubox        % the bbox as a polygon 2-tuple
        inpoly_flip   % used to flip the inpoly test to determine the signed distance.
        memory_gb     % memory in GB allowed to use for initial rejector
        cleanup       % logical flag to trigger cleaning of topology (default on).
        direc_smooth  % logical flag to trigger direct smoothing of mesh in the cleanup
        dj_cutoff     % the cutoff area fraction for disjoint portions to delete
        grd = msh();  % create empty mesh class to return p and t in.
        big_mesh
        ns_fix        % improve spacing for boundary vertices
        qual          % mean, lower 3rd sigma, and the minimum element quality.
        proj          % structure containing the m_map projection info
    end
    
    
    methods
        
        % class constructor/default grd generation options
        function obj = meshgen(varargin)
            p = inputParser;
            % unpack options and set default ones, catch errors.
            
            defval = 0; % placeholder value if arg is not passed.
            % add name/value pairs
            addOptional(p,'h0',defval);
            addOptional(p,'bbox',defval);
            addOptional(p,'fh',defval);
            addOptional(p,'pfix',defval);
            addOptional(p,'egfix',defval);
            addOptional(p,'inner',defval);
            addOptional(p,'outer',defval);
            addOptional(p,'mainland',defval);
            addOptional(p,'bou',defval);
            addOptional(p,'ef',defval);
            addOptional(p,'plot_on',defval);
            addOptional(p,'nscreen',defval);
            addOptional(p,'itmax',defval);
            addOptional(p,'memory_gb',1);
            addOptional(p,'cleanup',1);
            addOptional(p,'direc_smooth',1);
            addOptional(p,'dj_cutoff',0.25);
            addOptional(p,'big_mesh',defval);
            addOptional(p,'ns_fix',defval);
            addOptional(p,'proj',defval);
            
            % parse the inputs
            parse(p,varargin{:});
            
            %if isempty(varargin); return; end
            % store the inputs as a struct
            inp = p.Results;
            
            % kjr...order these argument so they are processed in a predictable
            % manner. Process the general opts first, then the OceanMesh
            % classes...then basic non-critical options. 
            inp = orderfields(inp,{'h0','bbox','fh','inner','outer','mainland',...
                                   'bou','ef',... %<--OceanMesh classes come after
                                   'egfix','pfix',...
                                   'plot_on','nscreen','itmax','memory_gb','cleanup',...
                                   'direc_smooth','dj_cutoff',...
                                   'big_mesh','ns_fix','proj'});             
            % get the fieldnames of the edge functions
            fields = fieldnames(inp);
            % loop through and determine which args were passed.
            % also, assign reasonable default values if some options were
            % not assigned.
            for i = 1 : numel(fields)
                type = fields{i};
                switch type
                    % parse aux options first
                    case('h0')
                        % Provide in meters
                        obj.h0 = inp.(fields{i});
                    case('fh')
                        if isa(inp.(fields{i}),'function_handle')
                            obj.fh = inp.(fields{i});
                        end
                        % can't check for errors here yet.
                    case('bbox')
                        obj.bbox= inp.(fields{i});
                        if iscell(obj.bbox)
                            % checking bbox extents
                            ob_min = obj.bbox{1}(:,1);
                            ob_max = obj.bbox{1}(:,2);
                            for ii = 2:length(obj.bbox)
                                if any(obj.bbox{ii}(:,1) < ob_min) || ...
                                        any(obj.bbox{ii}(:,2) > ob_max)
                                    error(['Outer bbox must contain all ' ...
                                        'inner bboxes: inner box #' ...
                                        num2str(ii) ' violates this'])
                                end
                            end
                        end
                        
                        % if user didn't pass anything explicitly for
                        % bounding box make it empty so it can be populated
                        % from ef as a cell-array
                        if obj.bbox(1)==0
                            obj.bbox = [];
                        end
                    case('pfix')
                        obj.pfix= inp.(fields{i});
                        if obj.pfix(1)~=0
                            obj.pfix = inp.(fields{i});
                        else
                            obj.pfix = [];
                        end
                        if  ~isempty(obj.bou{1}.weirPfix)
                           obj.pfix = [obj.pfix ; obj.bou{1}.weirPfix];
                        end
                    case('egfix')
                        obj.egfix= inp.(fields{i});
                        if obj.egfix(1)~=0
                            obj.egfix = inp.(fields{i});
                        else
                            obj.egfix = [];
                        end
                         if ~isempty(obj.bou{1}.weirEgfix)
                           obj.egfix = [obj.egfix ; obj.bou{1}.weirEgfix+length(obj.egfix)];
                        end
                    case('bou')
                        % got it from user arg
                        if obj.outer~=0, continue; end
                        
                        obj.outer = {} ; 
                        obj.inner = {} ; 
                        obj.mainland = {} ;
                        
                        obj.bou = inp.(fields{i});
                        
                        % handle when not a cell
                        if ~iscell(obj.bou)
                            boutemp = obj.bou;
                            obj.bou = cell(1);
                            obj.bou{1} = boutemp;
                        end
                        
                        % then the geodata class was provide, unpack
                        for ee = 1:length(obj.bou)
                            try
                                arg = obj.bou{ee} ;
                            catch
                                arg = obj.bou;
                            end
                            if isa(arg,'geodata')
                                obj.outer{ee} = obj.bou{ee}.outer;
                                obj.inner{ee} = obj.bou{ee}.inner;
                                if ~isempty(obj.inner{ee})
                                    obj.outer{ee} = [obj.outer{ee};
                                        obj.inner{ee}];
                                end
                                obj.mainland{ee} = obj.bou{ee}.mainland;
                                obj.boubox{ee} = obj.bou{ee}.boubox;
                                obj.inpoly_flip{ee} = obj.bou{ee}.inpoly_flip;
                                if obj.big_mesh
                                    % release gdat's
                                    obj.bou{ee}.mainland= [];
                                    obj.bou{ee}.outer= [];
                                    if ~isempty(obj.bou{ee}.inner)
                                        obj.bou{ee}.inner= [];
                                    end
                                end
                            end
                        end
                        
                    case('ef')
                        tmp = inp.(fields{i});
                        if isa(tmp, 'function_handle')
                            error('Please specify your edge function handle through the name/value pair fh'); 
                        end
                        obj.ef = tmp; 
                        
                        % handle when not a cell
                        if ~iscell(obj.ef)
                            eftemp = obj.ef;
                            obj.ef = cell(1);
                            obj.ef{1} = eftemp;
                        end
                        
                        % Gather boxes from ef class.
                        for ee = 1 : length(obj.ef)
                            if isa(obj.ef{ee},'edgefx')
                                obj.bbox{ee} = obj.ef{ee}.bbox;
                            end
                        end
                        
                         % checking bbox extents
                        if iscell(obj.bbox)
                            ob_min = obj.bbox{1}(:,1);
                            ob_max = obj.bbox{1}(:,2);
                            for ii = 2:length(obj.bbox)
                                if any(obj.bbox{ii}(:,1) < ob_min) || ...
                                        any(obj.bbox{ii}(:,2) > ob_max)
                                    error(['Outer bbox must contain all ' ...
                                        'inner bboxes: inner box #' ...
                                        num2str(ii) ' violates this'])
                                end
                            end
                        end
                        
                        % kjr 2018 June: get h0 from edge functions
                        for ee = 1:length(obj.ef)
                            if isa(obj.ef{ee},'edgefx')
                                obj.h0(ee) = obj.ef{ee}.h0;
                            end
                        end
                        
                        % kjr 2018 smooth the outer automatically
                        if length(obj.ef) > 1
                            obj.ef = smooth_outer(obj.ef);
                        end
                        
                        % Save the ef interpolants into the edgefx
                        for ee = 1:length(obj.ef)
                            if isa(obj.ef{ee},'edgefx')
                                obj.fh{ee} = @(p)obj.ef{ee}.F(p);
                            end
                        end
                        
                    case('plot_on')
                        obj.plot_on= inp.(fields{i});
                    case('big_mesh')
                        obj.big_mesh = inp.(fields{i});
                    case('ns_fix')
                        obj.ns_fix   = inp.(fields{i});
                    case('nscreen')
                        obj.nscreen= inp.(fields{i});
                        if obj.nscreen ~=0
                            obj.nscreen = inp.(fields{i});
                            obj.plot_on = 1;
                        else
                            obj.nscreen = 5; % default
                        end
                    case('itmax')
                        obj.itmax= inp.(fields{i});
                        if obj.itmax ~=0
                            obj.itmax = inp.(fields{i});
                        else
                            obj.itmax = 100;
                            warning('No itmax specified, itmax set to 100');
                        end
                    case('inner')
                        if ~isa(obj.bou,'geodata')
                            obj.inner = inp.(fields{i});
                        end
                    case('outer')
                        if ~isa(obj.bou,'geodata')
                            obj.outer = inp.(fields{i});
                            if obj.inner(1)~=0
                                obj.outer = [obj.outer; obj.inner];
                            end
                        end
                    case('mainland')
                        if ~isa(obj.bou,'geodata') 
                            obj.mainland = inp.(fields{i});
                        end
                    case('memory_gb')
                        if ~isa(obj.bou,'memory_gb')
                            obj.memory_gb = inp.(fields{i});
                        end
                    case('cleanup')
                        obj.cleanup = inp.(fields{i});
                    case('dj_cutoff')
                        obj.dj_cutoff = inp.(fields{i});
                    case('direc_smooth')
                        obj.direc_smooth = inp.(fields{i});
                    case('proj')
                        obj.proj = inp.(fields{i});
                        % default CPP
                        if obj.proj == 0; obj.proj = 'equi'; end
                        if ~isempty(obj.bbox)
                            % kjr Oct 2018 use outer coarsest box for
                            % multiscale meshing
                            lon_mi = obj.bbox{1}(1,1)-obj.h0(1)/1110;
                            lon_ma = obj.bbox{1}(1,2)+obj.h0(1)/1110;
                            lat_mi = obj.bbox{1}(2,1)-obj.h0(1)/1110;
                            lat_ma = obj.bbox{1}(2,2)+obj.h0(1)/1110;
                        else
                            lon_mi = -180; lon_ma = 180; 
                            lat_mi = -90; lat_ma = 90;
                        end 
                        % Set up projected space 
                        dmy = msh() ; 
                        dmy.p(:,1) = [lon_mi; lon_ma];
                        dmy.p(:,2) = [lat_mi; lat_ma];
                        del = setProj(dmy,1,obj.proj) ;
                end
            end
            
            if isempty(varargin); return; end
            
            % error checking
            if isempty(obj.boubox) && ~isempty(obj.bbox)
                % Make the bounding box 5 x 2 matrix in clockwise order if
                % it isn't present. This case must be when the user is
                % manually specifying the PSLG. 
                obj.boubox{1} = [obj.bbox(1,1) obj.bbox(2,1);
                                 obj.bbox(1,1) obj.bbox(2,2); ...
                                 obj.bbox(1,2) obj.bbox(2,2);
                                 obj.bbox(1,2) obj.bbox(2,1); ...
                                 obj.bbox(1,1) obj.bbox(2,1); NaN NaN];
            end
            if any(obj.h0==0), error('h0 was not correctly specified!'), end
            if isempty(obj.outer), error('no outer boundary specified!'), end
            if isempty(obj.bbox), error('no bounding box specified!'), end
            obj.fd = @dpoly;  % <-default distance fx accepts p and pv (outer polygon).
            
            global MAP_PROJECTION MAP_COORDS MAP_VAR_LIST
            obj.grd.proj    = MAP_PROJECTION ; 
            obj.grd.coord   = MAP_COORDS ; 
            obj.grd.mapvar  = MAP_VAR_LIST ; 
        
        end

        function  obj = build(obj)
            %DISTMESH2D 2-D Mesh Generator using Distance Functions.
            % Checking existence of major inputs
            %%
            warning('off','all')
            %%
            tic
            it = 1 ;
            imp = 10; % number of iterations to do mesh improvements (delete/add)
            imp2 = imp;
            Re = 6378.137e3;
            geps = 1e-3*min(obj.h0)/Re; 
            deps = sqrt(eps); %*min(obj.h0)/111e3;
            ttol=0.1; Fscale = 1.2; deltat = 0.1;
            % unpack initial points.
            p = obj.grd.p;
            if isempty(p)
                disp('Forming initial point distribution...');
                % loop over number of boxes
                for box_num = 1:length(obj.h0)
                    disp(['    for box #' num2str(box_num)]);
                    % checking if cell or not and applying local values
                    h0_l = obj.h0(box_num);
                    if ~iscell(obj.bbox)
                        bbox_l = obj.bbox'; % <--we must tranpose this!
                    else
                        bbox_l = obj.bbox{box_num}'; % <--tranpose!
                    end
                    if ~iscell(obj.fh)
                        fh_l = obj.fh;
                    else
                        fh_l = obj.fh{box_num};
                    end 
                    % Lets estimate the num_points the distribution will be
                    num_points = ceil(2/sqrt(3)*prod(abs(diff(bbox_l)))...
                                      /(h0_l/111e3)^2);
                    noblks = ceil(num_points*2*8/obj.memory_gb*1e-9);
                    len = abs(bbox_l(1,1)-bbox_l(2,1));
                    blklen = floor(len)/noblks;
                    st = bbox_l(1,1) ; ed = st + blklen; ns = 1;
                    %% 1. Create initial distribution in bounding box
                    %% (equilateral triangles)
                    for blk = 1 : noblks
                        if blk == noblks
                            ed = bbox_l(2,1);
                        end
                        ys = bbox_l(1,2);
                        ny = floor(1e3*m_lldist(repmat(0.5*(st+ed),2,1),...
                                   [ys;bbox_l(2,2)])/h0_l);   
                        dy = diff(bbox_l(:,2))/ny;
                        ns = 1;
                        % start at lower left and make grid going up to
                        % north latitude
                        for ii = 1:ny
                            if st*ed < 0 
                                nx = floor(1e3*m_lldist([st;0],...
                                     [ys;ys])/(2/sqrt(3)*h0_l)) + ...
                                     floor(1e3*m_lldist([0;ed],...
                                     [ys;ys])/(2/sqrt(3)*h0_l));
                            else
                                nx = floor(1e3*m_lldist([st;ed],...
                                     [ys;ys])/(2/sqrt(3)*h0_l));
                            end
                            ne = ns+nx-1;
                            if mod(ii,2) == 0
                                % no offset
                                x(ns:ne) = linspace(st,ed,nx);
                            else
                                % offset
                                dx = (ed-st)/nx;
                                x(ns:ne) = linspace(st+0.5*dx,ed,nx);
                            end
                            y(ns:ne) = ys;
                            ns = ne+1; ys = ys + dy;
                        end
                        st = ed;
                        ed = st + blklen;
                        p1 = [x(:) y(:)]; clear x y
                        %% 2. Remove points outside the region, apply the rejection method
                        p1 = p1(feval(obj.fd,p1,obj,box_num) < geps,:);     % Keep only d<0 points
                        r0 = 1./feval(fh_l,p1).^2;                          % Probability to keep point
                        max_r0 = 1/h0_l^2;     
                        p1 = p1(rand(size(p1,1),1) < r0/max_r0,:);          % Rejection method
                        p  = [p; p1];                                       % Adding p1 to p
                    end
                end
            else
                imp = 5; % number of iterations to do mesh improvements (delete/add)
                h0_l = obj.h0(end); % finest h0 (in case of a restart of meshgen.build).
            end
            
            % remove pfix/egfix outside of domain
            nfix = size(obj.pfix,1);    % Number of fixed points
            negfix = size(obj.egfix,1); % Number of edge constraints.
            if negfix > 0
                % remove bars if midpoint is outside domain
                egfix_mid = (obj.pfix(obj.egfix(:,1),:) + obj.pfix(obj.egfix(:,2),:))/2;
                inbar = inpoly(egfix_mid,obj.boubox{1}(1:end-1,:));
                obj.egfix(~inbar,:) = [];
                tmppfix = obj.pfix(unique(obj.egfix(:)),:);
                obj.pfix = []; obj.pfix = tmppfix;
                obj.egfix = renumberEdges(obj.egfix);
            elseif nfix > 0
                % remove pfix if outside domain
                in = inpoly(obj.pfix,obj.boubox{1}(1:end-1,:));
                obj.pfix(~in,:) = [];
            end
            
            if nfix >= 0, disp(['Using ',num2str(nfix),' fixed points.']);end
            if negfix > 0
                if max(obj.egfix(:)) > length(obj.pfix)
                    error('FATAL: Egfix does index correcty into pfix.');
                end
            end
            if ~isempty(obj.pfix); p = [obj.pfix; p]; end
            N = size(p,1); % Number of points N
            disp(['Number of initial points after rejection is ',num2str(N)]);
            %% Iterate
            pold = inf;                                                    % For first iteration
            if obj.plot_on >= 1
                clf,view(2),axis equal;
            end
            toc
            fprintf(1,' ------------------------------------------------------->\n') ;
            disp('Begin iterating...');
            while 1
                tic
                if mod(it,obj.nscreen) == 0
                    disp(['Iteration =' num2str(it)]) ;
                end
                
                % 3. Retriangulation by the Delaunay algorithm
                if max(sqrt(sum((p-pold).^2,2))/h0_l*111e3) > ttol         % Any large movement?
                    p = fixmesh(p);                                        % Ensure only unique points.
                    N = size(p,1); pold = p;                               % Save current positions
                    t = delaunay_elim(p,obj.fd,geps,0);                    % Delaunay with elimination
                    
                    % 4. Describe each bar by a unique pair of nodes.
                    bars = [t(:,[1,2]); t(:,[1,3]); t(:,[2,3])];           % Interior bars duplicated
                    bars = unique(sort(bars,2),'rows');                    % Bars as node pairs
                    
                    % 5. Graphical output of the current mesh
                    if obj.plot_on >= 1 && (mod(it,obj.nscreen)==0 || it == 1)
                        cla,m_triplot(p(:,1),p(:,2),t)
                        m_grid
                        title(['Iteration = ',num2str(it)]);
                        if ~isempty(obj.pfix)
                            hold on;
                            m_plot(p(1:nfix,1),p(1:nfix,2),'r.')
                        end
                        plt = cell2mat(obj.boubox');
                        % reduce point spacing for asecthics
                        [plt2(:,2),plt2(:,1)] = my_interpm(plt(:,2),plt(:,1),0.1) ; 
                        hold on ; axis manual
                        m_plot(plt2(:,1),plt2(:,2),'g','linewi',2)
                        drawnow
                    end
                end
                
                % Getting element quality and check goodness
                if exist('pt','var'); clear pt; end
                [pt(:,1),pt(:,2)] = m_ll2xy(p(:,1),p(:,2));
                tq = gettrimeshquan( pt, t);
                mq_m = mean(tq.qm);
                mq_l = min(tq.qm);
                mq_s = std(tq.qm);
                mq_l3sig = mq_m - 3*mq_s;
                obj.qual(it,:) = [mq_m,mq_l3sig,mq_l];
                % Termination quality, mesh quality reached is copacetic.
                if mod(it,imp2) == 0
                    if abs(mq_l3sig - obj.qual(max(1,it-imp2),2)) < 0.01
                        % Do the final elimination of small connectivity
                        [t,p] = delaunay_elim(p,obj.fd,geps,1);
                        disp('Quality of mesh is good enough, exit')
                        close all;
                        break;
                    end
                end
                
                % Saving a temp mesh
                if mod(it,obj.nscreen) == 0
                    disp(['Number of nodes is ' num2str(length(p))])
                    disp(['Mean mesh quality is ' num2str(mq_m)])
                    disp(['Min mesh quality is ' num2str(mq_l)])
                    disp(['3rd sigma lower mesh quality is ' num2str(mq_l3sig)])
                    tempp = p; tempt = t;
                    save('Temp_grid.mat','it','tempp','tempt');
                    clearvars tempp tempt
                end
                
                % 6. Move mesh points based on bar lengths L and forces F
                barvec = pt(bars(:,1),:)- pt(bars(:,2),:);                 % List of bar vectors
                long   = zeros(length(bars)*2,1);                          % 
                lat    = zeros(length(bars)*2,1);
                long(1:2:end) = p(bars(:,1),1); 
                long(2:2:end) = p(bars(:,2),1);
                lat(1:2:end)  = p(bars(:,1),2);  
                lat(2:2:end)  = p(bars(:,2),2);
                %Get spherical earth distances
                L = m_lldist(long,lat); L = L(1:2:end)*1e3;                % L = Bar lengths in meters
                ideal_bars = (p(bars(:,1),:) + p(bars(:,2),:))/2;          % Used to determine what bars are in bbox
                hbars = 0*ideal_bars(:,1);
                                
                for box_num = 1:length(obj.h0)                             % For each bbox, find the bars that are in and calculate
%                     if ~iscell(obj.bbox)                                  % their ideal lengths.
%                         bbox_l = obj.bbox;         
%                     else
%                         bbox_l = obj.bbox{box_num}; 
%                     end
                    if ~iscell(obj.fh)
                        fh_l = obj.fh;
                    else
                        fh_l = obj.fh{box_num};
                    end
                    h0_l = obj.h0(box_num);
                    if box_num > 1
                        h0_l = h0_l/111e3;                                 % create buffer to evalulate fh between nests
                        iboubox = obj.boubox{box_num}(1:end-1,:) ; 
                        inside = inpoly(ideal_bars,iboubox) ; 
%                         inside = (ideal_bars(:,1) >= bbox_l(1,1) - h0_l & ...
%                             ideal_bars(:,1) <= bbox_l(1,2) + h0_l & ...
%                             ideal_bars(:,2) >= bbox_l(2,1) - h0_l & ...
%                             ideal_bars(:,2) <= bbox_l(2,2) + h0_l);
                    else
                        inside = true(size(hbars));
                    end
                    hbars(inside) = feval(fh_l,ideal_bars(inside,:));       % Ideal lengths
                end
                
                L0 = hbars*Fscale*median(L)/median(hbars);                  % L0 = Desired lengths using ratio of medians scale factor
                LN = L./L0;                                                 % LN = Normalized bar lengths
                
                % Mesh improvements (deleting and addition)
                if mod(it,imp) == 0
                    % Remove elements with small connectivity
                    nn = get_small_connectivity(p,t);
                    disp(['Deleting ' num2str(length(nn)) ' due to small connectivity'])
                    
                    % Remove points that are too close (< LN = 0.5)
                    if any(LN < 0.5)
                        % Do not delete pfix too close.
                        nn1 = setdiff(reshape(bars(LN < 0.5,:),[],1),[(1:nfix)']);
                        disp(['Deleting ' num2str(length(nn1)) ' points too close together'])
                        nn = unique([nn; nn1]);
                    end
                    
                    % Split long edges however many times to
                    % better lead to LN of 1
                    pst = [];
                    if any(LN > 2)
                        nsplit = floor(LN);
                        nsplit(nsplit < 1) = 1;
                        adding = 0;
                        % Probably we can just split once?
                        for jj = 2:2
                            il = find(nsplit >= jj);
                            xadd = zeros(length(il),jj-1);
                            yadd = zeros(length(il),jj-1);
                            for jjj = 1 : length(il)
                                deltax = (p(bars(il(jjj),2),1)- p(bars(il(jjj),1),1))/jj;
                                deltay = (p(bars(il(jjj),2),2)- p(bars(il(jjj),1),2))/jj;
                                xadd(jjj,:) = p(bars(il(jjj),1),1) + (1:jj-1)*deltax;
                                yadd(jjj,:) = p(bars(il(jjj),1),2) + (1:jj-1)*deltay;
                            end
                            pst = [pst; xadd(:) yadd(:)];
                            adding = numel(xadd) + adding;
                        end
                        disp(['Adding ',num2str(adding) ,' points.'])
                    end
                    % Doing the actual subtracting and add
                    p(nn,:)= [];
                    p = [p; pst]; %-->p is duplicated here but 'setdiff' at the top of the while
                    pold = inf; it = it + 1;
                    continue;
                end
                
                F    = (1-LN.^4).*exp(-LN.^4)./LN;                         % Bessens-Heckbert edge force
                Fvec = F*[1,1].*barvec;
                
                Ftot = full(sparse(bars(:,[1,1,2,2]),ones(size(F))*[1,2,1,2],[Fvec,-Fvec],N,2));
                Ftot(1:nfix,:) = 0;                                        % Force = 0 at fixed points
                pt = pt + deltat*Ftot;                                     % Update node positions
                
                [p(:,1),p(:,2)] = m_xy2ll(pt(:,1),pt(:,2));  
                
                %7. Bring outside points back to the boundary
                d = feval(obj.fd,p,obj,[],0); ix = d>0;                    % Find points outside (d>0)
                ix(1:nfix)=0;
                if sum(ix) > 0
                    dgradx = (feval(obj.fd,[p(ix,1)+deps,p(ix,2)],obj,[],0)...
                              -d(ix))/deps; % Numerical 
                    dgrady = (feval(obj.fd,[p(ix,1),p(ix,2)+deps],obj,[],0)...
                              -d(ix))/deps; % gradient
                    dgrad2 = dgradx.^+2 + dgrady.^+2;
                    p(ix,:) = p(ix,:)-[d(ix).*dgradx./dgrad2,...
                                       d(ix).*dgrady./dgrad2];
                end
                
                % 8. Termination criterion: Exceed itmax
                it = it + 1 ;
                
                if ( it > obj.itmax )
                    % Do the final deletion of small connectivity
                    [t,p] = delaunay_elim(p,obj.fd,geps,1);
                    disp('too many iterations, exit')
                    close all;
                    break ;
                end
                toc
            end
            %%
            warning('on','all')
            %%
            disp('Finished iterating...');
            fprintf(1,' ------------------------------------------------------->\n') ;
            
            %% Doing the final cleaning and fixing to the mesh...
            % Clean up the mesh if specified
            if obj.cleanup 
                % Put the mesh class into the grd part of meshgen and clean
                obj.grd.p = p; obj.grd.t = t;
                db = 1;   % delete bad boundaries
                con = 9;  % reduce connectivity to max of 9
                prj = 1;  % project
                [obj.grd,qout] = clean(obj.grd,db,obj.direc_smooth,con,...
                                   obj.dj_cutoff,obj.nscreen,obj.pfix,prj);
                obj.qual(end+1,:) = qout;
            else
                % Fix mesh on the projected space
                [p1(:,1),p1(:,2)] = m_ll2xy(p(:,1),p(:,2)); 
                [p,t1] = fixmesh(p1,t);
                % Put the mesh class into the grd part of meshgen
                obj.grd.p = p; obj.grd.t = t1;
            end
            
            % Check element order, important for the global meshes crossing
            % -180/180 boundary
            obj.grd = CheckElementOrder(obj.grd);
            
            if obj.plot_on
                figure; plot(obj.qual,'linewi',2);
                hold on
                % plot the line dividing cleanup and distmesh
                plot([it it],[0 1],'--k')
                xticks(1:5:obj.itmax);
                xlabel('Iterations'); ylabel('Geometric element quality');
                title('Geometric element quality with iterations');
                set(gca,'FontSize',14);
                legend('q_{mean}','q_{mean}-q_{3\sigma}', 'q_{min}','Location','best');
                grid minor
            end
            return;
            %%%%%%%%%%%%%%%%%%%%%%%%%%
            % Auxiliary subfunctions %
            %%%%%%%%%%%%%%%%%%%%%%%%%%
            
            function [t,p] = delaunay_elim(p,fd,geps,final)
                % Removing mean to reduce the magnitude of the points to
                % help the convex calc
                if exist('pt1','var'); clear pt1; end
                [pt1(:,1),pt1(:,2)] = m_ll2xy(p(:,1),p(:,2));
                p_s  = pt1 - repmat(mean(pt1),[N,1]);
                if isempty(obj.egfix)
                    TR   = delaunayTriangulation(p_s);
                else
                    TR   = delaunayTriangulation(p_s(:,1),p_s(:,2),obj.egfix);
                end
                for kk = 1:final+1
                    if kk > 1
                        % Perform the following below upon exit from the mesh
                        % generation algorithm
                        nn = get_small_connectivity(p,t);
                        TR.Points(nn,:) = []; 
                        p(nn,:) = []; pt1(nn,:) = [];
                    end
                    t = TR.ConnectivityList;
                    pmid = squeeze(mean(reshape(pt1(t,:),[],3,2),2));      % Compute centroids
                    [pmid(:,1),pmid(:,2)] = m_xy2ll(pmid(:,1),pmid(:,2));  % Change back to lat lon
                    t    = t(feval(fd,pmid,obj,[]) < -geps,:);             % Keep interior triangles
                    % Deleting very straight triangles
                    tq_n = gettrimeshquan( pt1, t);
                    bad_ele = any(tq_n.vang < 1*pi/180 | ...
                                  tq_n.vang > 179*pi/180,2);
                    t(bad_ele,:) = [];
                end
            end
            
            function nn = get_small_connectivity(p,t)
                % Get node connectivity (look for 4)
                [~, enum] = VertToEle(t);
                % Make sure they are not boundary nodes
                bdbars = extdom_edges2(t, p);
                bdnodes = unique(bdbars(:));
                I = find(enum <= 4);
                nn = setdiff(I',[(1:nfix)';bdnodes]);                      % and don't destroy pfix or egfix!
                return;
            end
            
        end % end distmesh2d_plus
        
        function obj = nearshorefix(obj)
            %% kjr make sure boundaries have good spacing on boundary.
            % This is experimentary. 
            t = obj.grd.t ; p = obj.grd.t;
            [bnde, ~] = extdom_edges2(t,p);
            [poly]  = extdom_polygon(bnde,p,1);

            new = [];
            for j = 1 : length(poly)
                for i = 1 : length(poly{j})-2
                    pt = poly{j}(i,:) ; % current point
                    nxt= poly{j}(i+1,:) ; % next point
                    nxt2 = poly{j}(i+2,:) ; % next next point

                    dst1 = sqrt( (nxt(:,1)-pt(:,1)).^2 + (nxt(:,2)-pt(:,2)).^2 );     % dist to next point
                    dst2 = sqrt( (nxt2(:,1)-nxt(:,1)).^2 + (nxt2(:,2)-nxt(:,2)).^2 ); % dist to next next point

                    if dst2/dst1 > 2
                        % split bar
                        q = (nxt2 + nxt)/2;
                        new = [new; q];
                    end
                end
            end
            p = [p; new]; % post fix new points (to avoid problems with pfix.)
            t = delaunay_elim(p,obj.fd,geps,0);       % Delaunay with elimination
            obj.grd.t = t ; obj.grd.p = t;
        end
        
        
    end % end methods
    
end % end class

